import { generateKeyPairSync, createHmac, randomBytes, sign as edSign, createHash } from 'node:crypto';
import https from 'node:https';
import http from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createAgent } from '../src/server.mjs';
import { rawPublicKey, sha256, deviceIdOf } from '../src/identity.mjs';
import { signingString } from '../src/auth.mjs';
import { verifyPairingResponse } from '../src/pairing.mjs';

export const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/** A scratch state dir with a short path (unix sockets are limited to ~100 bytes). */
export function scratch(prefix = 'ia-') { const dir = realpathSync(mkdtempSync(path.join(tmpdir(), prefix))); return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) }; }

/** An in-memory keychain, so tests never touch the real one. */
export const memoryKeychain = () => { let value = null; return { read: () => value, write: (v) => { value = v; }, remove: () => { value = null; } }; };

/**
 * A scripted stand-in for iTalk's gateway (the real protocol: `/v2/account`, `/v2/models`, durable `/v2/tasks` with an event log and SSE replay).
 * `script(request, index)` returns what the "model" does for each step: { parts: [{text}|{reasoning}|{tool:{id,name,args}}|{delayMs}|{dropConnection}], status?, code?, fail? }.
 * `request` is shaped like a chat-completion body (`messages` with role/content/tool_calls/tool_call_id) so scripts read naturally.
 */
export async function fakeGateway(script, { models = [{ id: 'fake-model', name: 'Fake', developer: 'Test', contextTokens: 128_000, supportsTools: true, supportsReasoning: false, supportsImages: false, available: true, usageWeight: 1 }],
                                           subscription = { status: 'active', tier: 'plus', planName: 'Test' }, accountStatus = 200 } = {}) {
  const requests = [], tasks = new Map(), submits = [], logouts = [];
  let counter = 0;
  const json = (res, status, body, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', ...headers }); res.end(JSON.stringify(body)); };
  const toChat = (messages) => messages.map(m => ({ role: m.role, content: m.text, ...(m.toolCalls ? { tool_calls: m.toolCalls.map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.arguments } })) } : {}), ...(m.toolCallId ? { tool_call_id: m.toolCallId } : {}) }));
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://gw');
    const authorized = /^Bearer \S{20,}$/.test(req.headers.authorization ?? '');
    if (req.method === 'GET' && url.pathname === '/v2/models') return json(res, 200, { models });
    if (req.method === 'GET' && url.pathname === '/v2/account') {
      if (!authorized || accountStatus === 401) return json(res, 401, { error: { code: 'unauthorized' } });
      return json(res, 200, { subscription, models: models.map(m => m.id) });
    }
    let body = ''; req.on('data', c => body += c); req.on('end', async () => {
      if (!authorized) return json(res, 401, { error: { code: 'unauthorized' } });
      if (req.method === 'POST' && url.pathname === '/v2/auth/logout') { logouts.push(req.headers.authorization); res.writeHead(204); return res.end(); }
      if (req.method === 'POST' && url.pathname === '/v2/tasks') {
        const key = req.headers['idempotency-key']; submits.push(key);
        const existing = [...tasks.values()].find(t => t.key === key);
        if (existing) return json(res, 200, { task: { id: existing.id } });
        const parsed = JSON.parse(body); const chat = { ...parsed, messages: toChat(parsed.messages) };
        requests.push({ ...chat, key });
        const plan = await script(chat, requests.length - 1);
        if (plan.status) return json(res, plan.status, { error: { code: plan.code ?? 'internal_error' } }, plan.retryAfter ? { 'retry-after': String(plan.retryAfter) } : {});
        const id = `task-${++counter}-${Math.random().toString(16).slice(2, 10)}`;
        const task = { id, key, events: [], done: false, aborted: false, dropAt: null, plan };
        tasks.set(id, task);
        void (async () => {
          const push = (type, data) => task.events.push({ seq: task.events.length + 1, type, data });
          for (const part of plan.parts ?? []) {
            if (task.aborted) break;
            if (part.text) push('delta', { text: part.text });
            if (part.reasoning) push('reasoning', { text: part.reasoning });
            if (part.tool) push('tool_call', { id: part.tool.id, name: part.tool.name, arguments: JSON.stringify(part.tool.args ?? {}) });
            if (part.dropConnection) task.dropAt = task.events.length;
            if (part.delayMs) await sleep(part.delayMs);
          }
          if (task.aborted) push('cancelled', {});
          else if (plan.fail) push('failed', { code: plan.fail });
          else { push('usage', { inputTokens: 100, cachedInputTokens: 0, outputTokens: 20, reasoningTokens: 0 }); push('completed', { finishReason: plan.parts?.some(p => p.tool) ? 'toolCalls' : 'stop' }); }
          task.done = true;
        })();
        return json(res, 201, { task: { id } });
      }
      const m = /^\/v2\/tasks\/([\w-]+)\/(stream|cancel)$/.exec(url.pathname);
      const task = m && tasks.get(m[1]);
      if (!task) return json(res, 404, { error: { code: 'task_not_found' } });
      if (m[2] === 'cancel') { task.aborted = true; return json(res, 200, { task: { id: task.id } }); }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      let last = Number(url.searchParams.get('after') ?? 0), dropped = false;
      const first = !task.streamed; task.streamed = true;
      for (;;) {
        while (last < task.events.length) {
          const e = task.events[last]; last = e.seq;
          res.write(`id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
          if (first && task.dropAt && last >= task.dropAt && !dropped) { dropped = true; return res.destroy(); }
          if (['completed', 'failed', 'cancelled'].includes(e.type)) return res.end();
        }
        if (task.done) return res.end();
        await sleep(10);
        if (res.destroyed) return;
      }
    });
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, requests, submits, tasks, logouts, close: () => { server.closeAllConnections?.(); return new Promise(r => server.close(r)); } };
}
export const fakeModelServer = fakeGateway;

/** The phone side of the protocol, in Node. The Swift client implements the same bytes. */
export class TestPhone {
  constructor({ name = 'Test iPhone' } = {}) {
    const { privateKey } = generateKeyPairSync('ed25519');
    this.privateKey = privateKey; this.publicRaw = rawPublicKey(privateKey); this.publicKey = this.publicRaw.toString('base64url'); this.name = name;
  }
  get id() { return this.phoneId; }

  async pair(link, { port }) {
    const q = new URL(link).searchParams;
    const p = { key: q.get('k'), pin: q.get('p'), pairingId: q.get('i'), secret: q.get('s'), id: deviceIdOf(Buffer.from(q.get('k'), 'base64url')) };
    this.agent = { port, pin: p.pin, key: p.key, id: p.id };
    const nonce = randomBytes(12).toString('base64url');
    const proof = createHmac('sha256', p.secret).update(`pair|${p.pairingId}|${this.publicKey}|${nonce}`).digest().toString('base64url');
    const res = await this.raw('POST', '/v1/pair', { pairingId: p.pairingId, phonePublicKey: this.publicKey, phoneName: this.name, nonce, proof });
    if (res.status === 200) {
      this.phoneId = res.json.phoneId;
      const ok = verifyPairingResponse({ agentPublicKey: p.key, pairingId: p.pairingId, phonePublicKey: this.publicKey, agentDeviceId: p.id, nonce, signature: res.json.signature });
      if (!ok) throw new Error('agent identity could not be verified');
    }
    return res;
  }

  /** Unsigned request with the same certificate pinning the app uses. */
  raw(method, pathAndQuery, body, headers = {}) {
    return new Promise((resolve, reject) => {
      const payload = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body));
      const req = https.request({ host: '127.0.0.1', port: this.agent.port, method, path: pathAndQuery, rejectUnauthorized: false, headers: { 'content-type': 'application/json', 'content-length': payload.length, ...headers },
        checkServerIdentity: (_host, cert) => (sha256(cert.raw).toString('base64url') === this.agent.pin ? undefined : new Error('pin mismatch')) }, (res) => {
        const chunks = []; res.on('data', c => chunks.push(c));
        res.on('end', () => { const text = Buffer.concat(chunks).toString(); let json = null; try { json = JSON.parse(text); } catch {} resolve({ status: res.statusCode, json, text, headers: res.headers }); });
      });
      req.on('error', reject); req.end(payload);
    });
  }

  signedHeaders(method, pathAndQuery, body, { time = Date.now(), nonce = randomBytes(12).toString('base64url') } = {}) {
    const payload = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body));
    const sig = edSign(null, Buffer.from(signingString({ method, path: pathAndQuery, time, nonce, body: payload })), this.privateKey).toString('base64url');
    return { 'x-italk-key': this.phoneId, 'x-italk-time': String(time), 'x-italk-nonce': nonce, 'x-italk-sig': sig };
  }

  call(method, pathAndQuery, body, extra = {}) { return this.raw(method, pathAndQuery, body, { ...this.signedHeaders(method, pathAndQuery, body, extra.sign), ...(extra.headers ?? {}) }); }

  /** Server-Sent Events with resume: returns when the terminal event arrives or `until` returns true; `drop` closes the connection early. */
  stream(taskId, { after = 0, until, dropAfter } = {}) {
    return new Promise((resolve, reject) => {
      const pathAndQuery = `/v1/tasks/${taskId}/stream?after=${after}`;
      const events = [];
      const req = https.request({ host: '127.0.0.1', port: this.agent.port, method: 'GET', path: pathAndQuery, rejectUnauthorized: false, headers: this.signedHeaders('GET', pathAndQuery),
        checkServerIdentity: (_h, cert) => (sha256(cert.raw).toString('base64url') === this.agent.pin ? undefined : new Error('pin mismatch')) }, (res) => {
        if (res.statusCode !== 200) { let t = ''; res.on('data', c => t += c); res.on('end', () => reject(new Error(`stream ${res.statusCode} ${t}`))); return; }
        let buffer = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          buffer += chunk; let i;
          while ((i = buffer.indexOf('\n\n')) >= 0) {
            const block = buffer.slice(0, i); buffer = buffer.slice(i + 2);
            const id = block.match(/^id: (\d+)$/m), type = block.match(/^event: (.+)$/m), data = block.match(/^data: (.+)$/m);
            if (!id || !type) continue;
            events.push({ seq: Number(id[1]), type: type[1], data: JSON.parse(data[1]) });
            if (until?.(events.at(-1), events)) { req.destroy(); resolve({ events, closed: 'until' }); return; }
            if (dropAfter && events.length >= dropAfter) { req.destroy(); resolve({ events, closed: 'dropped' }); return; }
          }
        });
        res.on('end', () => resolve({ events, closed: 'server' }));
      });
      req.on('error', (e) => { if (e.code === 'ECONNRESET' && events.length) resolve({ events, closed: 'reset' }); else reject(e); });
      req.end();
    });
  }
}

/** Starts an agent in a scratch directory with an auto-approved pairing and returns a paired phone. `gateway` (a fakeGateway) gives it model access. */
export async function startPaired({ config = {}, gateway, fetcher, localFetcher, home, web, opener, sleep: sleepFn, stateDir, scratchDir, keychain = memoryKeychain(), phone: knownPhone } = {}) {
  const sc = scratchDir ? { dir: scratchDir, cleanup: () => {} } : scratch();
  const homeDir = home ?? path.join(sc.dir, 'home'); mkdirSync(path.join(homeDir, 'work'), { recursive: true });
  const cfg = { name: 'Test Mac', port: 0, publicUrls: [], roots: [homeDir], maxPermissionMode: 'ask', approvalTimeoutMinutes: 1, retentionDays: 30, maxConcurrentTasks: 2, ...config };
  const dir = stateDir ?? path.join(sc.dir, 's');
  const agent = await createAgent({ stateDir: dir, config: cfg, fetcher, localFetcher, keychain, web, opener, sleep: sleepFn ?? (() => Promise.resolve()), autoApprovePairing: true, home: homeDir });
  if (gateway) agent.backends.access.save({ gateway: typeof gateway === 'string' ? gateway : gateway.url, token: 'test-credential-0123456789abcdef', accountHint: 'tester' });
  const port = await agent.listen({ port: 0, host: '127.0.0.1' });
  if (knownPhone) { knownPhone.agent = { ...knownPhone.agent, port }; return { agent, phone: knownPhone, port, home: homeDir, workspace: path.join(homeDir, 'work'), sc, keychain, async stop() { await agent.close(); sc.cleanup(); } }; }
  const phone = new TestPhone();
  agent.pairing.endpoints = [`https://127.0.0.1:${port}`];
  const begun = agent.pairing.begin();
  const res = await phone.pair(begun.uri, { port });
  if (res.status !== 200) throw new Error(`pairing failed ${res.status} ${res.text}`);
  return { agent, phone, port, home: homeDir, workspace: path.join(homeDir, 'work'), sc, keychain, async stop() { await agent.close(); sc.cleanup(); } };
}
