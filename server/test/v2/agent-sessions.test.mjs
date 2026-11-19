import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../../src/v2/db.mjs';
import { createApp } from '../../src/v2/app.mjs';
import { Pricing } from '../../src/v2/plans.mjs';

// A paired computer reasons through the person's own account (subscription, quota, ledger) with a credential that can do exactly that.

const fast = { N: 1 << 10, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
const provider = { async *generate() { yield { type: 'delta', text: 'ok' }; yield { type: 'usage', inputTokens: 10, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0, searches: 0 }; yield { type: 'finish', reason: 'stop' }; } };

async function boot() {
  const db = openDb(':memory:');
  const app = createApp({ db, pricing: new Pricing(), provider, now: () => Date.now(), accountsOptions: { scryptParams: fast } });
  await new Promise(r => app.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const api = async (method, path, { token, body, headers = {} } = {}) => {
    const response = await fetch(base + path, { method, headers: { ...(body ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
    const text = await response.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
    return { status: response.status, json, text };
  };
  return { db, api, close: async () => { await app.close(); db.close(); } };
}

async function signup(t, email, subscribe) {
  const r = await t.api('POST', '/v2/auth/register', { body: { email, password: 'a-long-password', displayName: '测试' } });
  assert.equal(r.status, 201, r.text);
  if (subscribe) {
    const now = Date.now();
    t.db.prepare('INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,updated_at) VALUES(?,?,?,?,?,?,?,?,?)')
      .run('orig-' + email, r.json.account.id, 'com.italk.cloud.monthly', 'active', 'Sandbox', now - 3600_000, now + 29 * 86_400_000, 1, now);
  }
  return { token: r.json.session.token, account: r.json.account };
}
const taskBody = () => ({ model: 'deepseek-flash', messages: [{ role: 'user', text: 'hi' }], tools: [], maxTokens: 100 });

test('a computer credential runs model tasks under the account and sees no profile', async (t) => {
  const g = await boot(); t.after(g.close);
  const phone = await signup(g, 'a@example.com', true);
  const made = await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: '我的 MacBook' } });
  assert.equal(made.status, 201, made.text);
  const mac = made.json.session;
  assert.ok(mac.token && mac.token !== phone.token && mac.expiresAt > Date.now());
  assert.equal(mac.name, 'Mac · 我的 MacBook');

  const account = await g.api('GET', '/v2/account', { token: mac.token });
  assert.equal(account.status, 200);
  assert.equal(account.json.account, undefined, 'the computer never sees the profile');
  assert.equal(account.json.subscription.status, 'active');
  assert.ok(account.json.models.includes('deepseek-flash'));

  const task = await g.api('POST', '/v2/tasks', { token: mac.token, body: taskBody(), headers: { 'idempotency-key': 'mac-task-0001/1' } });
  assert.equal(task.status, 201, task.text);
  const events = await g.api('GET', `/v2/tasks/${task.json.task.id}/events`, { token: mac.token });
  assert.equal(events.status, 200);
  assert.equal((await g.api('POST', `/v2/tasks/${task.json.task.id}/cancel`, { token: mac.token })).status, 200);
  assert.equal((await g.api('GET', '/v2/models')).status, 200);
});

test('a computer credential cannot touch anything else', async (t) => {
  const g = await boot(); t.after(g.close);
  const phone = await signup(g, 'b@example.com', true);
  const mac = (await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: 'Mac' } })).json.session;
  const denied = [
    ['GET', '/v2/account/sessions'], ['POST', '/v2/auth/logout-all'], ['PATCH', '/v2/account', { displayName: 'x' }], ['DELETE', '/v2/account', {}],
    ['POST', '/v2/agent-sessions', { name: 'another' }], ['GET', '/v2/usage'], ['POST', '/v2/iap/transactions', { signedTransactions: [] }],
    ['GET', '/v2/tasks'], ['PUT', '/v2/account/avatar'], ['POST', '/v2/account/password', { current: 'a', next: 'b' }],
  ];
  for (const [method, path, body] of denied) {
    const r = await g.api(method, path, { token: mac.token, body });
    assert.equal(r.status, 403, `${method} ${path} → ${r.status} ${r.text}`);
    assert.equal(r.json.error.code, 'forbidden_scope');
  }
  // …while the phone's own session still can.
  assert.equal((await g.api('GET', '/v2/account/sessions', { token: phone.token })).status, 200);
});

test('the phone lists and revokes the computer; setting the same computer up again replaces its credential', async (t) => {
  const g = await boot(); t.after(g.close);
  const phone = await signup(g, 'c@example.com', true);
  const first = (await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: 'Studio' } })).json.session;
  const second = (await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: 'Studio' } })).json.session;
  assert.equal((await g.api('GET', '/v2/account', { token: first.token })).status, 401, 'the earlier credential of the same computer is gone');
  assert.equal((await g.api('GET', '/v2/account', { token: second.token })).status, 200);
  const list = await g.api('GET', '/v2/account/sessions', { token: phone.token });
  const entry = list.json.sessions.find(s => s.scope === 'agent');
  assert.equal(entry.deviceName, 'Mac · Studio');
  assert.equal(list.json.sessions.filter(s => s.scope === 'agent').length, 1);
  assert.equal((await g.api('DELETE', `/v2/account/sessions/${entry.id}`, { token: phone.token })).status, 204);
  assert.equal((await g.api('GET', '/v2/account', { token: second.token })).status, 401);
});

test('without a subscription the computer is told so instead of failing silently', async (t) => {
  const g = await boot(); t.after(g.close);
  const phone = await signup(g, 'd@example.com', false);
  const mac = (await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: 'Mac' } })).json.session;
  const status = await g.api('GET', '/v2/account', { token: mac.token });
  assert.equal(status.json.subscription.status, 'none');
  const task = await g.api('POST', '/v2/tasks', { token: mac.token, body: taskBody(), headers: { 'idempotency-key': 'mac-task-0002/1' } });
  assert.equal(task.status, 402);
  assert.equal(task.json.error.code, 'subscription_required');
});

test('only a few computers per account', async (t) => {
  const g = await boot(); t.after(g.close);
  const phone = await signup(g, 'e@example.com', true);
  const tokens = [];
  for (let i = 0; i < 10; i++) tokens.push((await g.api('POST', '/v2/agent-sessions', { token: phone.token, body: { name: `Mac ${i}` } })).json.session.token);
  const live = [];
  for (const token of tokens) live.push((await g.api('GET', '/v2/account', { token })).status === 200);
  assert.equal(live.filter(Boolean).length, 8);
  assert.deepEqual(live.slice(0, 2), [false, false], 'the least recently used ones are dropped first');
});
