import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { mkdirSync, chmodSync, rmSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import { readdir } from 'node:fs/promises';
import { AgentError, openDb } from './db.mjs';
import { loadOrCreateIdentity, ensureTlsCertificate } from './identity.mjs';
import { Pairing } from './pairing.mjs';
import { RequestAuth } from './auth.mjs';
import { Tasks, TERMINAL } from './tasks.mjs';
import { PathPolicy } from './policy.mjs';
import { createBackends, endpoints as listEndpoints, lanAddresses, computerName } from './config.mjs';

export { AGENT_VERSION } from './version.mjs';
import { AGENT_VERSION } from './version.mjs';
import { controlSocketPath } from './control-client.mjs';
const MAX_BODY = 2_000_000;
export const platformLabel = (platform = process.platform) => ({ darwin: 'macOS', linux: 'Linux', win32: 'Windows' })[platform] ?? 'Other';

class RateLimiter {
  constructor(limit, windowMs, now) { Object.assign(this, { limit, windowMs, now }); this.hits = new Map(); }
  allow(key) {
    const t = this.now(), list = (this.hits.get(key) ?? []).filter(x => x > t - this.windowMs);
    list.push(t); this.hits.set(key, list);
    if (this.hits.size > 2000) for (const [k, v] of this.hits) if (!v.some(x => x > t - this.windowMs)) this.hits.delete(k);
    return list.length <= this.limit;
  }
}

/** Counts failures only: ten bad signatures a minute from one address earn a short pause; good traffic is never limited. */
class FailureLimiter {
  constructor(limit, windowMs, now) { Object.assign(this, { limit, windowMs, now }); this.fails = new Map(); }
  record(key) { const t = this.now(), list = (this.fails.get(key) ?? []).filter(x => x > t - this.windowMs); list.push(t); this.fails.set(key, list); }
  allow(key) { const t = this.now(), list = (this.fails.get(key) ?? []).filter(x => x > t - this.windowMs); if (!list.length) this.fails.delete(key); return list.length < this.limit; }
}

const readBody = (req, limit = MAX_BODY) => new Promise((resolve, reject) => {
  const chunks = []; let size = 0;
  req.on('data', (c) => { size += c.length; if (size > limit) { reject(new AgentError('body_too_large', 413)); req.destroy(); } else chunks.push(c); });
  req.on('end', () => resolve(Buffer.concat(chunks)));
  req.on('error', reject);
});
const parseJson = (buf) => { if (!buf.length) return {}; try { return JSON.parse(buf.toString('utf8')); } catch { throw new AgentError('invalid_json', 400); } };
const send = (res, status, body, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers }); res.end(JSON.stringify(body)); };
const sendError = (res, error) => {
  if (!(error instanceof AgentError)) error = new AgentError('internal_error', 500);
  if (res.headersSent) return res.end();
  send(res, error.status, { error: { code: error.code, ...(error.detail ? { detail: error.detail } : {}) } });
};

export async function createAgent({ stateDir, config, fetcher, localFetcher, keychain, web, opener, sleep, now = () => Date.now(), log = () => {}, home = homedir(), autoApprovePairing = false, dnssd = false }) {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const identity = loadOrCreateIdentity(stateDir);
  const tls = ensureTlsCertificate(stateDir, { hostnames: [], addresses: lanAddresses() });
  const db = openDb(path.join(stateDir, 'agent.sqlite'));
  // CONTEXT MEMORY
  // Updated: 2026-11-02
  // Status: verified
  // Why: A custom state directory can be inside an otherwise allowed workspace.
  // Debug Goal: Keep agent credentials and task records inaccessible to its own tools.
  // Search Tags: custom agent state directory protected workspace credentials
  // Invariants:
  // - Always deny the actual configured state directory, not just the default path.
  // - A broader allowed root must never override this denial.
  // Failure Modes:
  // - A task reads its own credential or another task's private database.
  const policy = new PathPolicy({ roots: config.roots, home, extraDeny: [stateDir] });
  const backends = await createBackends(config, { db, home, fetcher, localFetcher, stateDir, keychain, web, opener, sleep, now, log });
  const italk = backends.get('italk');
  const notifyHooks = [];
  const tasks = new Tasks({ db, backends, policy, home, maxMode: config.maxPermissionMode, maxConcurrent: config.maxConcurrentTasks, retentionMs: config.retentionDays * 86_400_000,
    approvalTimeoutMs: config.approvalTimeoutMinutes * 60_000, now, log, notify: (e) => notifyHooks.forEach(h => { try { h(e); } catch {} }) });
  // While a task runs (or waits for the person's answer) the Mac must not fall asleep, or the phone could not reach it.
  let awake = null;
  tasks.on('busy', (count) => {
    if (count > 0 && !awake) {
      const child = spawn('/usr/bin/caffeinate', ['-i', '-w', String(process.pid)], { stdio: 'ignore' });
      child.unref();                                   // never keeps this process alive; `-w` ends it when this process ends
      child.on('error', () => { if (awake === child) awake = null; }); child.on('exit', () => { if (awake === child) awake = null; });
      awake = child;
    } else if (count === 0 && awake) { awake.kill(); awake = null; }
  });
  const auth = new RequestAuth({ db, now });
  let pairSession = null;
  const pairing = new Pairing({ db, identity, tls, endpoints: [], name: config.name ?? computerName(), now,
    approve: async (phone) => (autoApprovePairing ? true : pairSession ? pairSession.confirm(phone) : false) });
  const unsignedLimit = new RateLimiter(30, 60_000, now);
  const authFailures = new FailureLimiter(10, 60_000, now);
  const streams = new Map();       // phoneId → open SSE count
  let port = config.port, probeCache = { at: 0, value: null };

  const probeBackends = async () => {
    if (probeCache.value && now() - probeCache.at < 10_000) return probeCache.value;
    // CONTEXT MEMORY
    // Updated: 2026-11-02
    // Status: inferred
    // Why: An offline cloud service must not indefinitely delay discovering local models.
    // Debug Goal: Report each backend independently and bound status latency.
    // Search Tags: local model discovery cloud timeout status
    // Invariants:
    // - Probe all backends concurrently with a bounded wait.
    // - An unresponsive backend is reported unavailable, never ready.
    // Failure Modes:
    // - A slow cloud probe makes a working local model appear unreachable.
    const out = await Promise.all([...backends.values()].map(async b => {
      let timer;
      const timeout = new Promise(resolve => { timer = setTimeout(() => resolve({ available: false, detail: 'probe_timeout' }), 4000); });
      const p = await Promise.race([b.probe().catch(() => ({ available: false, detail: 'probe failed' })), timeout]);
      clearTimeout(timer);
      return { id: b.id, name: b.name, kind: b.kind, available: Boolean(p.available), detail: p.detail ?? null, models: p.models ?? [], modelInfo: p.modelInfo ?? [], defaultModel: p.defaultModel ?? null, subscription: p.subscription ?? null, ...(b.capabilities?.() ?? {}) };
    }));
    probeCache = { at: now(), value: out };
    return out;
  };

  const status = async (phone) => ({
    agent: { id: identity.deviceId, name: config.name ?? computerName(), version: AGENT_VERSION, platform: platformLabel(), fingerprint: identity.fingerprint },
    backends: await probeBackends(),
    limits: { maxPermissionMode: config.maxPermissionMode, maxConcurrentTasks: config.maxConcurrentTasks, approvalTimeoutMinutes: config.approvalTimeoutMinutes, retentionDays: config.retentionDays },
    roots: policy.roots, home: policy.home, phone: { id: phone.phoneId, name: phone.phoneName }, time: now(),
  });

  function streamTask(req, res, phoneId, taskId, after) {
    const snapshot = tasks.get(phoneId, taskId);
    if ((streams.get(phoneId) ?? 0) >= 8) throw new AgentError('too_many_streams', 429);
    streams.set(phoneId, (streams.get(phoneId) ?? 0) + 1);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write(': ok\n\n');
    let last = after, live = false, closed = false, heartbeat = null, unsubscribe = () => {};
    const buffer = [];
    const finish = () => { if (closed) return; closed = true; clearInterval(heartbeat); unsubscribe(); streams.set(phoneId, Math.max(0, (streams.get(phoneId) ?? 1) - 1)); res.end(); };
    const emit = (e) => { if (e.seq <= last) return false; last = e.seq; res.write(`id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`); return TERMINAL.has(e.type); };
    res.on('close', finish);
    unsubscribe = tasks.subscribe(taskId, (e) => { if (closed) return; if (!live) buffer.push(e); else if (emit(e)) finish(); });
    for (;;) {
      const batch = tasks.events(phoneId, taskId, last, 500);
      for (const e of batch) if (emit(e)) return finish();
      if (batch.length < 500) break;
    }
    live = true;
    for (const e of buffer) if (emit(e)) return finish();
    if (TERMINAL.has(tasks.get(phoneId, taskId).state) && snapshot.lastSeq <= last) return finish();
    heartbeat = setInterval(() => { try { res.write(': keep-alive\n\n'); } catch {} }, 15_000);
  }

  async function handle(req, res) {
    const started = now();
    const url = new URL(req.url, 'https://agent.local');
    const route = `${req.method} ${url.pathname}`;
    let phoneTag = '-';
    try {
      if (route === 'GET /v1/hello') {
        if (!unsignedLimit.allow(req.socket.remoteAddress)) throw new AgentError('too_many_requests', 429);
        return send(res, 200, { agent: { id: identity.deviceId, name: config.name ?? computerName(), version: AGENT_VERSION }, time: now() });
      }
      if (route === 'POST /v1/pair') {
        if (!unsignedLimit.allow(req.socket.remoteAddress)) throw new AgentError('too_many_requests', 429);
        return send(res, 200, await pairing.complete(parseJson(await readBody(req, 8192))));
      }
      const body = await readBody(req);
      if (!authFailures.allow(`fail:${req.socket.remoteAddress}`, true)) throw new AgentError('too_many_requests', 429);
      let phone;
      try { phone = auth.verify(req, body); } catch (error) { authFailures.record(`fail:${req.socket.remoteAddress}`); throw error; }
      phoneTag = phone.phoneId.slice(0, 6);
      const m = (re) => url.pathname.match(re);
      let match;
      if (route === 'GET /v1/status') return send(res, 200, await status(phone));
      // ---- model access: the iPhone hands over a credential for iTalk's gateway; there is no other way to give this computer a model ----
      if (route === 'GET /v1/cloud') return send(res, 200, { cloud: backends.access.describe() });
      if (route === 'PUT /v1/cloud') {
        const b = parseJson(body);
        try { backends.access.save({ gateway: b.gateway, token: b.token, expiresAt: b.expiresAt, accountHint: b.accountHint, sessionName: b.sessionName }); }
        catch (error) { throw new AgentError(error?.code ?? 'invalid_arguments', 400, String(error?.message ?? error).slice(0, 160)); }
        italk.invalidate(); probeCache = { at: 0, value: null };
        return send(res, 200, { cloud: backends.access.describe(), verification: await italk.verify({ force: true }) });
      }
      if (route === 'POST /v1/cloud/verify') { italk.invalidate(); probeCache = { at: 0, value: null }; return send(res, 200, { cloud: backends.access.describe(), verification: await italk.verify({ force: true }) }); }
      if (route === 'DELETE /v1/cloud') { const { revoked } = await backends.access.revoke(); italk.invalidate(); probeCache = { at: 0, value: null }; return send(res, 200, { cloud: backends.access.describe(), revoked }); }
      // ---- what this computer can do for the phone: tools, skills, the project's own instructions ----
      if (route === 'GET /v1/capabilities') {
        let cwd = url.searchParams.get('cwd') || null;
        if (cwd) { const c = policy.check(cwd); if (c.verdict !== 'root') throw new AgentError('cwd_not_allowed', 403); cwd = c.path; }
        return send(res, 200, { capabilities: { ...italk.describe({ cwd, policy }), agent: { version: AGENT_VERSION }, cloud: backends.access.describe() } });
      }
      if ((match = m(/^\/v1\/questions\/([0-9a-f-]{36})$/)) && req.method === 'POST') return send(res, 200, tasks.answerQuestion(phone.phoneId, match[1], parseJson(body).answer));
      if (route === 'POST /v1/tasks') {
        const out = tasks.create(phone.phoneId, req.headers['idempotency-key'], parseJson(body));
        return send(res, out.created ? 201 : 200, { task: out.task, ...(out.modeClamped ? { modeClamped: true } : {}) });
      }
      if (route === 'GET /v1/tasks') return send(res, 200, { tasks: tasks.list(phone.phoneId, { limit: Number(url.searchParams.get('limit') ?? 30) }) });
      if ((match = m(/^\/v1\/tasks\/([0-9a-f-]{36})$/))) {
        if (req.method === 'GET') return send(res, 200, { task: tasks.get(phone.phoneId, match[1]) });
        if (req.method === 'DELETE') { tasks.delete(phone.phoneId, match[1]); res.writeHead(204); return res.end(); }
      }
      if ((match = m(/^\/v1\/tasks\/([0-9a-f-]{36})\/(events|stream|cancel)$/))) {
        const after = Math.max(0, Number(url.searchParams.get('after') ?? req.headers['last-event-id'] ?? 0) || 0);
        if (match[2] === 'events' && req.method === 'GET') return send(res, 200, { events: tasks.events(phone.phoneId, match[1], after, Math.min(Number(url.searchParams.get('limit') ?? 500), 1000)), task: tasks.get(phone.phoneId, match[1]) });
        if (match[2] === 'stream' && req.method === 'GET') return streamTask(req, res, phone.phoneId, match[1], after);
        if (match[2] === 'cancel' && req.method === 'POST') return send(res, 200, { task: tasks.cancel(phone.phoneId, match[1]) });
      }
      if (route === 'GET /v1/approvals') return send(res, 200, { approvals: tasks.pending(phone.phoneId) });
      if ((match = m(/^\/v1\/approvals\/([0-9a-f-]{36})$/)) && req.method === 'POST') {
        const b = parseJson(body);
        return send(res, 200, tasks.resolveApproval(match[1], { decision: b.decision, scope: b.scope, by: phone.phoneId }, { phoneId: phone.phoneId }));
      }
      if (route === 'GET /v1/audit') return send(res, 200, { entries: tasks.recentAudit(phone.phoneId, Number(url.searchParams.get('limit') ?? 100)) });
      if (route === 'GET /v1/folders') {
        // Without a path (or with `~`) the picker starts at the home folder, or at the first allowed folder when the owner restricted the agent to other roots.
        const asked = url.searchParams.get('path');
        let c = policy.check(asked || '~', { cwd: policy.home });
        if (c.verdict !== 'root' && (!asked || asked === '~') && policy.roots.length) c = policy.check(policy.roots[0], { cwd: policy.home });
        if (c.verdict !== 'root') throw new AgentError('path_not_allowed', 403);
        const entries = await readdir(c.path, { withFileTypes: true }).catch(() => { throw new AgentError('not_found', 404); });
        const folders = entries.filter(e => e.isDirectory() && !e.name.startsWith('.') && policy.check(path.join(c.path, e.name)).verdict === 'root').map(e => e.name).sort((a, b) => a.localeCompare(b)).slice(0, 300);
        return send(res, 200, { path: c.path, parent: c.path === policy.home || policy.roots.includes(c.path) ? null : path.dirname(c.path), folders });
      }
      if (route === 'GET /v1/device') { const d = db.prepare('SELECT id,name,paired_at AS pairedAt,last_seen AS lastSeen FROM phones WHERE id=?').get(phone.phoneId); return send(res, 200, { device: d }); }
      if (route === 'DELETE /v1/device') { await revokePhone(phone.phoneId); res.writeHead(204); return res.end(); }
      throw new AgentError('not_found', 404);
    } catch (error) {
      if (!(error instanceof AgentError)) log('unhandled', { route, message: String(error?.message ?? error) });
      sendError(res, error);
    } finally {
      if (!res.writableEnded || res.statusCode >= 400) log('request', { route, status: res.statusCode, ms: now() - started, phone: phoneTag });
    }
  }

  async function revokePhone(phoneId) {
    db.prepare('UPDATE phones SET revoked_at=? WHERE id=?').run(now(), phoneId);
    for (const t of db.prepare("SELECT * FROM tasks WHERE phone_id=? AND state IN ('queued','running')").all(phoneId)) tasks.cancelRow(t);
    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: verified
    // Why: Model access belongs to the computer and is shared by paired phones.
    // Debug Goal: Unpair one phone without disabling another phone's model access.
    // Search Tags: unpair last phone shared cloud credential revoke
    // Invariants:
    // - Revoke shared access only after the final active phone is removed.
    // - The removed phone immediately loses access and its running tasks stop.
    // Failure Modes:
    // - Removing one phone clears another phone's cloud access.
    if (!db.prepare('SELECT 1 FROM phones WHERE revoked_at IS NULL LIMIT 1').get()) {
      const revocation = backends.access.revoke();
      italk.invalidate(); probeCache = { at: 0, value: null };
      await revocation;
    }
  }

  // ---------- local control (CLI ↔ service) ----------
  const controlPath = controlSocketPath(stateDir);
  let controlServer = null;
  const startControl = () => new Promise((resolve, reject) => {
    rmSync(controlPath, { force: true });
    controlServer = net.createServer((sock) => {
      sock.setEncoding('utf8');
      let buffer = '';
      const reply = (obj) => { if (!sock.destroyed) sock.write(JSON.stringify(obj) + '\n'); };
      let answerWaiter = null;
      const ask = (obj, timeoutMs = 90_000) => new Promise((resolveAnswer) => {
        const timer = setTimeout(() => { answerWaiter = null; resolveAnswer(false); }, timeoutMs);
        answerWaiter = (v) => { clearTimeout(timer); answerWaiter = null; resolveAnswer(v); };
        reply(obj);
      });
      sock.on('close', () => { if (answerWaiter) answerWaiter(false); if (pairSession?.sock === sock) pairSession = null; });
      sock.on('error', () => {});
      sock.on('data', (chunk) => {
        buffer += chunk;
        let i;
        while ((i = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
          if (!line.trim()) continue;
          let msg; try { msg = JSON.parse(line); } catch { continue; }
          if (msg.op === 'answer') { answerWaiter?.(Boolean(msg.approve)); continue; }
          control(msg, reply, ask, sock).catch((error) => reply({ type: 'error', code: error?.code ?? 'internal_error', message: String(error?.message ?? error) }));
        }
      });
    });
    controlServer.once('error', reject);
    controlServer.listen(controlPath, () => { chmodSync(controlPath, 0o600); resolve(); });
  });

  async function control(msg, reply, ask, sock) {
    switch (msg.op) {
      case 'status': return reply({ type: 'status', agent: { id: identity.deviceId, name: config.name, version: AGENT_VERSION, fingerprint: identity.fingerprint }, port, tasksRunning: tasks.running.size,
        devices: db.prepare('SELECT COUNT(*) AS n FROM phones WHERE revoked_at IS NULL').get().n, backends: await probeBackends(), endpoints: listEndpoints({ port, publicUrls: config.publicUrls }) });
      case 'devices': return reply({ type: 'devices', devices: db.prepare('SELECT id,name,paired_at AS pairedAt,last_seen AS lastSeen,revoked_at AS revokedAt FROM phones ORDER BY paired_at DESC').all() });
      case 'revoke': { if (!db.prepare('SELECT 1 FROM phones WHERE id=?').get(msg.id)) return reply({ type: 'error', code: 'unknown_device' }); await revokePhone(msg.id); return reply({ type: 'ok' }); }
      case 'tasks': return reply({ type: 'tasks', tasks: tasks.listAll({ limit: 50 }) });
      case 'approvals': return reply({ type: 'approvals', approvals: tasks.pending() });
      case 'resolve': { const out = tasks.resolveApproval(msg.id, { decision: msg.decision, scope: msg.scope ?? 'once', by: 'mac' }); return reply({ type: 'ok', approval: out.approval }); }
      case 'cancel': { const row = tasks.row(msg.id); if (!row) return reply({ type: 'error', code: 'task_not_found' }); tasks.cancelRow(row); return reply({ type: 'ok' }); }
      case 'pair': {
        if (pairSession) return reply({ type: 'error', code: 'pairing_in_progress' });
        pairing.endpoints = listEndpoints({ port, publicUrls: config.publicUrls });
        const begun = pairing.begin();
        pairSession = { sock, confirm: (phone) => ask({ type: 'confirm', phoneName: phone.name, fingerprint: phone.fingerprint, phoneId: phone.phoneId }) };
        reply({ type: 'qr', uri: begun.uri, expiresAt: begun.expiresAt, endpoints: pairing.endpoints, agentFingerprint: identity.fingerprint });
        const watch = setInterval(() => {
          if (sock.destroyed) return clearInterval(watch);
          if (now() > begun.expiresAt) { clearInterval(watch); pairSession = null; reply({ type: 'expired' }); }
          else if (db.prepare('SELECT 1 FROM phones WHERE revoked_at IS NULL AND paired_at>=?').get(begun.expiresAt - 5 * 60_000)) { clearInterval(watch); pairSession = null; reply({ type: 'paired' }); }
        }, 500);
        sock.on('close', () => clearInterval(watch));
        return;
      }
      case 'cloud': return reply({ type: 'cloud', cloud: backends.access.describe(), verification: msg.verify ? await italk.verify({ force: true }) : null });
      case 'skills': { const d = italk.describe({ cwd: null, policy }); return reply({ type: 'skills', skills: d.skills, userDir: italk.userSkillsDir }); }
      case 'shutdown': reply({ type: 'ok' }); setTimeout(() => process.kill(process.pid, 'SIGTERM'), 50); return;
      default: return reply({ type: 'error', code: 'unknown_op' });
    }
  }

  // ---------- lifecycle ----------
  let httpsServer = null, bonjour = null, purgeTimer = null;
  const api = {
    identity, tls, db, tasks, policy, backends, auth, pairing, config, stateDir, controlPath,
    onNotify: (fn) => notifyHooks.push(fn),
    get port() { return port; },
    async listen({ port: wanted = config.port, host = '::' } = {}) {
      tasks.recover();
      httpsServer = https.createServer({ key: tls.key, cert: tls.cert, minVersion: 'TLSv1.2', honorCipherOrder: true }, handle);
      httpsServer.keepAliveTimeout = 30_000; httpsServer.headersTimeout = 20_000;
      await new Promise((resolve, reject) => { httpsServer.once('error', reject); httpsServer.listen({ port: wanted, host, ipv6Only: false }, resolve); });
      port = httpsServer.address().port;
      await startControl();
      const housekeeping = () => {
        try { tasks.purge(); backends.sessions?.purge?.(config.retentionDays * 86_400_000); db.prepare('DELETE FROM audit WHERE at<?').run(now() - 90 * 86_400_000); } catch (error) { log('housekeeping_failed', { message: String(error?.message ?? error) }); }
        try { for (const f of readdirSync(path.join(stateDir, 'tmp'))) rmSync(path.join(stateDir, 'tmp', f), { force: true }); } catch {}
      };
      housekeeping();
      purgeTimer = setInterval(housekeeping, 6 * 3_600_000); purgeTimer.unref?.();
      if (dnssd) {
        bonjour = spawn('/usr/bin/dns-sd', ['-R', config.name ?? computerName(), '_italk-agent._tcp', '.', String(port), `id=${identity.deviceId}`, 'v=1'], { stdio: 'ignore' });
        bonjour.on('error', () => {});
      }
      return port;
    },
    async close() {
      clearInterval(purgeTimer); bonjour?.kill(); awake?.kill(); awake = null;
      tasks.shutdown(); await tasks.drain().catch(() => {});
      await new Promise(r => (httpsServer ? httpsServer.close(() => r()) : r())); httpsServer?.closeAllConnections?.();
      await new Promise(r => (controlServer ? controlServer.close(() => r()) : r()));
      rmSync(controlPath, { force: true });
      db.close();
    },
  };
  return api;
}
