import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createSign, createHash } from 'node:crypto';
import { openDb } from '../../src/v2/db.mjs';
import { createApp } from '../../src/v2/app.mjs';
import { Pricing, DEFAULT_PRICING, DEFAULT_PLANS, MICRO_PER_POINT } from '../../src/v2/plans.mjs';
import { AppleSignIn } from '../../src/v2/apple.mjs';

const fast = { N: 1 << 10, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/** A scripted provider: each call plays the next script. Steps: {delta|reasoning|tool_call|usage|finish|wait:ms|fail:code}. */
function fakeProvider(scripts) {
  const calls = [];
  return {
    calls,
    async *generate(request) {
      calls.push(request);
      const script = scripts.shift() ?? [{ delta: 'ok' }, { usage: [10, 0, 2] }, { finish: 'stop' }];
      for (const step of script) {
        if (request.signal?.aborted) return;
        if (step.wait) { await new Promise(r => { const t = setTimeout(r, step.wait); request.signal?.addEventListener('abort', () => { clearTimeout(t); r(); }, { once: true }); }); continue; }
        if (step.fail) { const { GatewayError } = await import('../../src/v2/db.mjs'); throw new GatewayError(step.fail, 502); }
        if (step.delta) yield { type: 'delta', text: step.delta };
        if (step.reasoning) yield { type: 'reasoning', text: step.reasoning };
        if (step.tool_call) yield { type: 'tool_call', ...step.tool_call };
        if (step.usage) yield { type: 'usage', inputTokens: step.usage[0], cachedInputTokens: step.usage[1], outputTokens: step.usage[2], reasoningTokens: 0, searches: 0 };
        if (step.finish) yield { type: 'finish', reason: step.finish };
      }
    },
  };
}

async function boot({ scripts = [], mailer = null, appleSignIn = null, verifier = null, now } = {}) {
  const db = openDb(':memory:');
  const provider = fakeProvider(scripts);
  const app = createApp({ db, pricing: new Pricing(), provider, mailer, appleSignIn, verifier, now: now ?? (() => Date.now()), accountsOptions: { scryptParams: fast } });
  await new Promise(r => app.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const api = async (method, path, { token, body, headers = {}, raw } = {}) => {
    const response = await fetch(base + path, { method, headers: { ...(body ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
      body: raw ?? (body ? JSON.stringify(body) : undefined) });
    const text = await response.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
    return { status: response.status, json, text, headers: response.headers, bytes: Buffer.from(text, 'binary') };
  };
  const close = async () => { await app.close(); db.close(); };
  return { db, app, provider, base, api, close };
}

async function signup(t, email = 'a@example.com', subscribe = true) {
  const r = await t.api('POST', '/v2/auth/register', { body: { email, password: 'a-long-password', displayName: '测试' } });
  assert.equal(r.status, 201, r.text);
  if (subscribe) {
    const now = Date.now();
    t.db.prepare('INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,updated_at) VALUES(?,?,?,?,?,?,?,?,?)')
      .run('orig-' + email, r.json.account.id, 'com.italk.cloud.monthly', 'active', 'Sandbox', now - 3600_000, now + 29 * 86_400_000, 1, now);
  }
  return { token: r.json.session.token, account: r.json.account };
}
const taskBody = (extra = {}) => ({ model: 'deepseek-flash', messages: [{ role: 'user', text: '你好' }], tools: [], maxTokens: 200, ...extra });

async function readSSE(response, { stopAfter = Infinity } = {}) {
  const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = '', events = [];
  while (events.length < stopAfter) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let i;
    while ((i = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, i); buffer = buffer.slice(i + 2);
      const id = /^id: (\d+)$/m.exec(block), type = /^event: (.+)$/m.exec(block), data = /^data: (.+)$/m.exec(block);
      if (id && type) events.push({ seq: Number(id[1]), type: type[1], data: JSON.parse(data[1]) });
    }
  }
  await reader.cancel().catch(() => {});
  return events;
}
async function waitTerminal(t, token, id) {
  for (let i = 0; i < 200; i++) { const r = await t.api('GET', `/v2/tasks/${id}`, { token }); if (['completed', 'failed', 'cancelled'].includes(r.json.task.state)) return r.json.task; await sleep(25); }
  throw new Error('task did not finish');
}

test('public routes describe what is really available', async (tt) => {
  const t = await boot(); tt.after(t.close);
  const c = (await t.api('GET', '/v2/capabilities')).json;
  assert.deepEqual([c.registration, c.passwordReset, c.signInWithApple, c.subscriptions], [true, false, false, false]);
  assert.equal((await t.api('POST', '/v2/auth/password-reset/request', { body: { email: 'a@b.co' } })).status, 503);
  assert.equal((await t.api('GET', '/v2/plans')).json.plans.length, DEFAULT_PLANS.length);
  const models = (await t.api('GET', '/v2/models')).json.models;
  assert.equal(models[0].id, 'deepseek-flash'); assert.equal(models[0].usageWeight, 1);
  assert.equal((await t.api('GET', '/v2/account')).status, 401);
});

test('profile: name, avatar, sessions, password, deletion over HTTP', async (tt) => {
  const t = await boot(); tt.after(t.close);
  const { token, account } = await signup(t, 'p@example.com', false);
  assert.equal((await t.api('PATCH', '/v2/account', { token, body: { displayName: '新名字' } })).json.account.displayName, '新名字');
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64, 7)]);
  const up = await fetch(t.base + '/v2/account/avatar', { method: 'PUT', headers: { authorization: `Bearer ${token}`, 'content-type': 'image/png' }, body: png });
  assert.equal(up.status, 200); assert.equal((await up.json()).account.hasAvatar, true);
  const got = await fetch(t.base + '/v2/account/avatar', { headers: { authorization: `Bearer ${token}` } });
  assert.equal(got.headers.get('content-type'), 'image/png'); assert.deepEqual(Buffer.from(await got.arrayBuffer()), png);
  const etag = got.headers.get('etag');
  assert.equal((await fetch(t.base + '/v2/account/avatar', { headers: { authorization: `Bearer ${token}`, 'if-none-match': etag } })).status, 304);
  assert.equal((await fetch(t.base + '/v2/account/avatar', { method: 'PUT', headers: { authorization: `Bearer ${token}`, 'content-type': 'image/png' }, body: Buffer.from('nope, text') })).status, 400);
  assert.equal((await t.api('DELETE', '/v2/account/avatar', { token })).json.account.hasAvatar, false);
  const second = (await t.api('POST', '/v2/auth/login', { body: { email: 'p@example.com', password: 'a-long-password', device: { name: 'iPad', platform: 'ios' } } })).json.session.token;
  assert.equal((await t.api('GET', '/v2/account/sessions', { token })).json.sessions.length, 2);
  assert.equal((await t.api('POST', '/v2/account/password', { token, body: { current: 'a-long-password', next: 'brand-new-password' } })).status, 204);
  assert.equal((await t.api('GET', '/v2/account', { token: second })).status, 401, 'other sessions end after a password change');
  assert.equal((await t.api('GET', '/v2/account', { token })).status, 200);
  assert.equal((await t.api('DELETE', '/v2/account', { token, body: { password: 'wrong' } })).status, 401);
  assert.equal((await t.api('DELETE', '/v2/account', { token, body: { password: 'brand-new-password' } })).status, 204);
  assert.equal((await t.api('GET', '/v2/account', { token })).status, 401);
  assert.ok(account.id);
});

test('cloud models need a subscription; everything else about the account works without one', async (tt) => {
  const t = await boot(); tt.after(t.close);
  const { token } = await signup(t, 'n@example.com', false);
  const r = await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'run-0001/1' }, body: taskBody() });
  assert.equal(r.status, 402); assert.equal(r.json.error.code, 'subscription_required');
  assert.equal(t.provider.calls.length, 0, 'nothing reached the provider');
  const acct = (await t.api('GET', '/v2/account', { token })).json;
  assert.equal(acct.subscription.status, 'none'); assert.equal(acct.subscription.windows, null);
});

test('a task streams, is billed from the provider usage, and its log replays exactly', async (tt) => {
  const t = await boot({ scripts: [[{ reasoning: '先想一想。' }, { delta: '你好' }, { delta: '，世界' }, { tool_call: { id: 'c1', name: 'weather_forecast', arguments: '{"place":"杭州"}' } }, { usage: [3000, 2000, 120] }, { finish: 'toolCalls' }]] });
  tt.after(t.close);
  const { token } = await signup(t);
  const created = await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'run-0001/1' }, body: taskBody({ runId: 'run-1', step: 1 }) });
  assert.equal(created.status, 201);
  const id = created.json.task.id;
  const live = await readSSE(await fetch(`${t.base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}` } }));
  assert.deepEqual(live.map(e => e.type), ['started', 'reasoning', 'delta', 'tool_call', 'usage', 'completed']);
  assert.deepEqual(live.map(e => e.seq), [1, 2, 3, 4, 5, 6]);
  assert.equal(live[2].data.text, '你好，世界', 'adjacent deltas are coalesced');
  assert.equal(live[5].data.finishReason, 'toolCalls');
  // a late reader gets the identical log from the beginning, and only the tail after a cursor
  const replay = await readSSE(await fetch(`${t.base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}` } }));
  assert.deepEqual(replay, live);
  const tail = await readSSE(await fetch(`${t.base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}`, 'last-event-id': '3' } }));
  assert.deepEqual(tail.map(e => e.seq), [4, 5, 6]);
  const polled = (await t.api('GET', `/v2/tasks/${id}/events?after=4`, { token })).json;
  assert.deepEqual(polled.events.map(e => e.seq), [5, 6]);
  // billing: exact cost from the provider's usage (2000 cached of 3000 input, 120 output)
  const expected = Math.ceil(1000 * 1.2 + 2000 * 0.12 + 120 * 2.4);
  const usage = (await t.api('GET', '/v2/usage', { token })).json.records;
  assert.equal(usage.length, 1); assert.equal(usage[0].points, Math.round(expected / MICRO_PER_POINT * 100) / 100);
  const sub = (await t.api('GET', '/v2/account', { token })).json.subscription;
  assert.equal(sub.windows.weekly.used, Math.round(expected / MICRO_PER_POINT * 10) / 10);
  assert.deepEqual(t.provider.calls[0].messages, [{ role: 'user', text: '你好' }]);
});

test('closing every connection does not stop the task, and a reconnect resumes without gaps or repeats', async (tt) => {
  const t = await boot({ scripts: [[{ delta: 'A' }, { wait: 150 }, { delta: 'B' }, { wait: 150 }, { delta: 'C' }, { usage: [100, 0, 3] }, { finish: 'stop' }]] });
  tt.after(t.close);
  const { token } = await signup(t);
  const id = (await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'k-12345678' }, body: taskBody() })).json.task.id;
  const first = await readSSE(await fetch(`${t.base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}` } }), { stopAfter: 2 });   // then the connection is dropped
  assert.deepEqual(first.map(e => e.type), ['started', 'delta']);
  await sleep(500);                                                               // nobody is listening
  const task = await waitTerminal(t, token, id);
  assert.equal(task.state, 'completed', 'the task finished without any reader');
  const rest = await readSSE(await fetch(`${t.base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}`, 'last-event-id': String(first.at(-1).seq) } }));
  const all = [...first, ...rest];
  assert.deepEqual(all.map(e => e.seq), [...Array(all.length).keys()].map(i => i + 1), 'no gaps, no repeats');
  assert.equal(all.filter(e => e.type === 'delta').map(e => e.data.text).join(''), 'ABC');
});

test('idempotent submission never bills or runs twice', async (tt) => {
  const t = await boot({ scripts: [[{ delta: 'x' }, { usage: [50, 0, 1] }, { finish: 'stop' }]] }); tt.after(t.close);
  const { token } = await signup(t);
  const headers = { 'idempotency-key': 'same-key-1' };
  const a = await t.api('POST', '/v2/tasks', { token, headers, body: taskBody() });
  const b = await t.api('POST', '/v2/tasks', { token, headers, body: taskBody() });
  assert.equal(a.status, 201); assert.equal(b.status, 200); assert.equal(a.json.task.id, b.json.task.id);
  await waitTerminal(t, token, a.json.task.id);
  const again = await t.api('POST', '/v2/tasks', { token, headers, body: taskBody() });
  assert.equal(again.status, 200); assert.equal(again.json.task.state, 'completed');
  assert.equal(t.provider.calls.length, 1);
  assert.equal(t.db.prepare('SELECT COUNT(*) AS n FROM usage').get().n, 1);
  assert.equal((await t.api('POST', '/v2/tasks', { token, headers, body: taskBody({ maxTokens: 300 }) })).json.error.code, 'idempotency_conflict');
  assert.equal((await t.api('POST', '/v2/tasks', { token, headers: {}, body: taskBody() })).json.error.code, 'idempotency_key_required');
});

test('cancel stops the provider call, bills only what was delivered, and is idempotent', async (tt) => {
  const t = await boot({ scripts: [[{ delta: 'part' }, { wait: 5000 }, { delta: 'never' }, { usage: [10, 0, 5] }, { finish: 'stop' }]] }); tt.after(t.close);
  const { token } = await signup(t);
  const id = (await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'cancel-me-1' }, body: taskBody() })).json.task.id;
  await sleep(200);
  const c1 = await t.api('POST', `/v2/tasks/${id}/cancel`, { token });
  assert.equal(c1.status, 200);
  const task = await waitTerminal(t, token, id);
  assert.equal(task.state, 'cancelled');
  assert.equal((await t.api('POST', `/v2/tasks/${id}/cancel`, { token })).json.task.state, 'cancelled');
  const events = (await t.api('GET', `/v2/tasks/${id}/events`, { token })).json.events;
  assert.equal(events.at(-1).type, 'cancelled'); assert.ok(!events.some(e => e.data.text === 'never'));
  const row = t.db.prepare('SELECT state, estimated FROM usage').get();
  assert.equal(row.state, 'settled'); assert.equal(row.estimated, 1);
});

test('provider failure before any output costs nothing', async (tt) => {
  const t = await boot({ scripts: [[{ fail: 'provider_request_failed' }]] }); tt.after(t.close);
  const { token } = await signup(t);
  const id = (await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'fail-1234' }, body: taskBody() })).json.task.id;
  const task = await waitTerminal(t, token, id);
  assert.equal(task.state, 'failed'); assert.equal(task.error, 'provider_request_failed');
  assert.equal(t.db.prepare('SELECT state FROM usage').get().state, 'released');
  assert.equal((await t.api('GET', '/v2/account', { token })).json.subscription.windows.weekly.used, 0);
});

test('quota, concurrency and isolation are enforced', async (tt) => {
  const t = await boot({ scripts: [[{ wait: 300 }, { delta: 'a' }, { usage: [10, 0, 1] }, { finish: 'stop' }], [{ wait: 300 }, { delta: 'b' }, { usage: [10, 0, 1] }, { finish: 'stop' }]] });
  tt.after(t.close);
  const me = await signup(t, 'me@example.com'), other = await signup(t, 'other@example.com', false);
  const ids = [];
  for (const k of ['conc-0001', 'conc-0002']) ids.push((await t.api('POST', '/v2/tasks', { token: me.token, headers: { 'idempotency-key': k }, body: taskBody() })).json.task.id);
  const third = await t.api('POST', '/v2/tasks', { token: me.token, headers: { 'idempotency-key': 'conc-0003' }, body: taskBody() });
  assert.equal(third.status, 429); assert.equal(third.json.error.code, 'too_many_concurrent_requests');
  assert.equal((await t.api('GET', `/v2/tasks/${ids[0]}`, { token: other.token })).status, 404, 'tasks belong to their account');
  assert.equal((await t.api('GET', `/v2/tasks/${ids[0]}/stream`, { token: other.token })).status, 404);
  assert.equal((await t.api('POST', `/v2/tasks/${ids[0]}/cancel`, { token: other.token })).status, 404);
  for (const id of ids) await waitTerminal(t, me.token, id);
  // weekly allowance: a request whose worst case exceeds what is left is refused before the provider is called
  t.db.prepare("INSERT INTO usage(id,account_id,model,state,reserved_micro,cost_micro,created_at) VALUES('burn',?, 'deepseek-flash','settled',0,?,?)")
    .run(me.account.id, DEFAULT_PLANS[0].weeklyPoints * MICRO_PER_POINT - 100, Date.now());
  const calls = t.provider.calls.length;
  const over = await t.api('POST', '/v2/tasks', { token: me.token, headers: { 'idempotency-key': 'over-0001' }, body: taskBody() });
  assert.equal(over.status, 429); assert.equal(over.json.error.detail.window, 'weekly');
  assert.equal(t.provider.calls.length, calls);
});

test('a restart ends in-flight tasks as interrupted and keeps what was produced', async (tt) => {
  const t = await boot(); tt.after(t.close);
  const { token, account } = await signup(t);
  const now = Date.now();
  t.db.prepare("INSERT INTO tasks(id,account_id,idem_key,request_digest,state,model,created_at,last_seq) VALUES('zombie-task-1',?, 'z-1234567','d','running','deepseek-flash',?,2)").run(account.id, now);
  t.db.prepare("INSERT INTO task_events(task_id,seq,type,payload,created_at) VALUES('zombie-task-1',1,'started','{}',?),('zombie-task-1',2,'delta','{\"text\":\"部分\"}',?)").run(now, now);
  t.db.prepare("INSERT INTO usage(id,account_id,task_id,model,state,reserved_micro,created_at) VALUES('hold',?, 'zombie-task-1','deepseek-flash','reserved',1000,?)").run(account.id, now);
  assert.equal(t.app.tasks.recover(), 1);
  const events = (await t.api('GET', '/v2/tasks/zombie-task-1/events', { token })).json.events;
  assert.deepEqual(events.map(e => e.type), ['started', 'delta', 'failed']); assert.equal(events[2].data.code, 'interrupted');
  assert.equal(t.db.prepare("SELECT state FROM usage WHERE id='hold'").get().state, 'settled');
});

test('task content is purged after the retention window; ids and cost remain', async (tt) => {
  let clock = Date.now();
  const t = await boot({ now: () => clock }); tt.after(t.close);
  const { token } = await signup(t);
  const id = (await t.api('POST', '/v2/tasks', { token, headers: { 'idempotency-key': 'purge-123' }, body: taskBody() })).json.task.id;
  await waitTerminal(t, token, id);
  assert.equal(t.app.tasks.purge(), 0);
  clock += 25 * 3_600_000;
  assert.equal(t.app.tasks.purge(), 1);
  assert.equal((await t.api('GET', `/v2/tasks/${id}/events`, { token })).json.events.length, 0);
  assert.equal((await t.api('GET', `/v2/tasks/${id}`, { token })).json.task.state, 'completed');
  assert.equal(t.db.prepare('SELECT request_json FROM tasks WHERE id=?').get(id).request_json, null);
  assert.equal((await t.api('GET', '/v2/usage', { token })).json.records.length, 1);
});

test('password reset works only with a mailer, never reveals accounts, and revokes sessions', async (tt) => {
  const sent = [];
  const t = await boot({ mailer: { send: async (m) => { sent.push(m); } } }); tt.after(t.close);
  assert.equal((await t.api('GET', '/v2/capabilities')).json.passwordReset, true);
  const { token } = await signup(t, 'r@example.com', false);
  assert.equal((await t.api('POST', '/v2/auth/password-reset/request', { body: { email: 'nobody@example.com' } })).status, 202);
  assert.equal(sent.length, 0);
  assert.equal((await t.api('POST', '/v2/auth/password-reset/request', { body: { email: 'R@example.com' } })).status, 202);
  assert.equal(sent.length, 1); assert.match(sent[0].code, /^[A-Z2-9]{8}$/);
  const bad = await t.api('POST', '/v2/auth/password-reset/confirm', { body: { email: 'r@example.com', code: 'WRONGONE', newPassword: 'another-password' } });
  assert.equal(bad.json.error.code, 'invalid_token');
  assert.equal((await t.api('POST', '/v2/auth/password-reset/confirm', { body: { email: 'r@example.com', code: sent[0].code, newPassword: 'another-password' } })).status, 204);
  assert.equal((await t.api('GET', '/v2/account', { token })).status, 401);
  assert.equal((await t.api('POST', '/v2/auth/login', { body: { email: 'r@example.com', password: 'another-password' } })).status, 200);
  assert.equal((await t.api('POST', '/v2/auth/password-reset/confirm', { body: { email: 'r@example.com', code: sent[0].code, newPassword: 'third-password' } })).status, 400, 'a code works once');
});

test('sign in with Apple verifies the identity token and links by subject', async (tt) => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'K1', alg: 'RS256', use: 'sig' };
  const issue = (claims, kid = 'K1') => {
    const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid })).toString('base64url'), p = Buffer.from(JSON.stringify(claims)).toString('base64url');
    return `${h}.${p}.${createSign('RSA-SHA256').update(`${h}.${p}`).sign(privateKey).toString('base64url')}`;
  };
  const nowS = Math.floor(Date.now() / 1000);
  // Flip a character in the middle of the signature. (The last base64url character of a 256-byte signature carries four padding bits that decoding ignores, so changing it can leave the token valid.)
  const tamper = (token) => { const i = token.lastIndexOf('.') + 40; return token.slice(0, i) + (token[i] === 'A' ? 'B' : 'A') + token.slice(i + 1); };
  const good = (extra = {}) => ({ iss: 'https://appleid.apple.com', aud: 'com.italk.assistant', sub: '001234.abcd', iat: nowS, exp: nowS + 600, email: 'me@privaterelay.appleid.com', email_verified: true, nonce: createHash('sha256').update('raw-nonce').digest('hex'), ...extra });
  const t = await boot({ appleSignIn: new AppleSignIn({ bundleId: 'com.italk.assistant', fetchKeys: async () => [jwk] }) }); tt.after(t.close);
  assert.equal((await t.api('GET', '/v2/capabilities')).json.signInWithApple, true);
  const first = await t.api('POST', '/v2/auth/apple', { body: { identityToken: issue(good()), nonce: 'raw-nonce', fullName: { given: '小', family: '明' } } });
  assert.equal(first.status, 200, first.text); assert.equal(first.json.isNewAccount, true); assert.equal(first.json.account.displayName, '小 明'); assert.deepEqual(first.json.account.signInMethods, ['apple']);
  const second = await t.api('POST', '/v2/auth/apple', { body: { identityToken: issue(good()), nonce: 'raw-nonce' } });
  assert.equal(second.json.isNewAccount, false); assert.equal(second.json.account.id, first.json.account.id);
  for (const [name, token, nonce] of [['wrong audience', issue(good({ aud: 'com.other.app' })), 'raw-nonce'], ['expired', issue(good({ exp: nowS - 10 })), 'raw-nonce'],
                                       ['wrong nonce', issue(good()), 'other-nonce'], ['unknown key', issue(good(), 'K9'), 'raw-nonce'], ['tampered', tamper(issue(good())), 'raw-nonce']]) {
    const r = await t.api('POST', '/v2/auth/apple', { body: { identityToken: token, nonce } });
    assert.equal(r.status, 401, name); assert.equal(r.json.error.code, 'invalid_identity_token');
  }
  // an Apple-only account deletes itself by presenting a fresh token for the same subject
  const del = await t.api('DELETE', '/v2/account', { token: first.json.session.token, body: { identityToken: issue(good()), nonce: 'raw-nonce' } });
  assert.equal(del.status, 204);
});

test('purchases are verified, bound to the buyer, restorable, and updated by notifications exactly once', async (tt) => {
  const decoded = new Map();
  const verifier = {
    verifyAndDecodeTransaction: async (jws) => { if (!decoded.has(jws)) throw new Error('bad signature'); return decoded.get(jws); },
    verifyAndDecodeRenewalInfo: async (jws) => decoded.get(jws),
    verifyAndDecodeNotification: async (jws) => { if (!decoded.has(jws)) throw new Error('bad signature'); return decoded.get(jws); },
  };
  const t = await boot({ verifier }); tt.after(t.close);
  assert.equal((await t.api('GET', '/v2/capabilities')).json.subscriptions, true);
  const buyer = await signup(t, 'buyer@example.com', false), other = await signup(t, 'other@example.com', false);
  const now = Date.now();
  const tr = (extra = {}) => ({ transactionId: '1001', originalTransactionId: '1000', productId: 'com.italk.cloud.monthly', type: 'Auto-Renewable Subscription', purchaseDate: now, expiresDate: now + 30 * 86_400_000,
                                environment: 'Sandbox', appAccountToken: buyer.account.appleAccountToken, ...extra });
  decoded.set('jws-ok', tr());
  const attached = await t.api('POST', '/v2/iap/transactions', { token: buyer.token, body: { signedTransactions: ['jws-ok'] } });
  assert.equal(attached.status, 200); assert.equal(attached.json.subscription.status, 'active'); assert.equal(attached.json.subscription.planId, 'com.italk.cloud.monthly');
  assert.equal(attached.json.subscription.windows.period.limit, DEFAULT_PLANS[0].periodPoints);
  // the same transaction cannot be claimed by another account, and forged data is refused
  assert.equal((await t.api('POST', '/v2/iap/transactions', { token: other.token, body: { signedTransactions: ['jws-ok'] } })).json.error.code, 'transaction_belongs_to_another_account');
  assert.equal((await t.api('POST', '/v2/iap/transactions', { token: buyer.token, body: { signedTransactions: ['forged'] } })).json.error.code, 'invalid_transaction');
  // restore: attaching again is harmless
  assert.equal((await t.api('POST', '/v2/iap/transactions', { token: buyer.token, body: { signedTransactions: ['jws-ok'] } })).status, 200);
  assert.equal(t.db.prepare('SELECT COUNT(*) AS n FROM subscriptions').get().n, 1);
  // renewal notification extends the period; the identical notification again changes nothing
  decoded.set('n-renew', { notificationUUID: 'u-1', notificationType: 'DID_RENEW', data: { signedTransactionInfo: 'jws-renewed' } });
  decoded.set('jws-renewed', tr({ transactionId: '1002', purchaseDate: now + 30 * 86_400_000, expiresDate: now + 60 * 86_400_000 }));
  assert.deepEqual((await t.api('POST', '/v2/iap/notifications', { body: { signedPayload: 'n-renew' } })).json, { duplicate: false, type: 'DID_RENEW' });
  assert.equal((await t.api('POST', '/v2/iap/notifications', { body: { signedPayload: 'n-renew' } })).json.duplicate, true);
  assert.equal((await t.api('GET', '/v2/account', { token: buyer.token })).json.subscription.periodEnd, now + 60 * 86_400_000);
  // refund ends access immediately
  decoded.set('n-refund', { notificationUUID: 'u-2', notificationType: 'REFUND', data: { signedTransactionInfo: 'jws-refund' } });
  decoded.set('jws-refund', tr({ transactionId: '1002', purchaseDate: now + 30 * 86_400_000, expiresDate: now + 60 * 86_400_000, revocationDate: now + 31 * 86_400_000 }));
  await t.api('POST', '/v2/iap/notifications', { body: { signedPayload: 'n-refund' } });
  const after = (await t.api('GET', '/v2/account', { token: buyer.token })).json.subscription;
  assert.equal(after.status, 'refunded'); assert.equal(after.windows, null);
  assert.equal((await t.api('POST', '/v2/tasks', { token: buyer.token, headers: { 'idempotency-key': 'after-refund' }, body: taskBody() })).status, 402);
  assert.equal((await t.api('POST', '/v2/iap/notifications', { body: { signedPayload: 'garbage' } })).status, 400);
});
