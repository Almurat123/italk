import http from 'node:http';
import https from 'node:https';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { GatewayError } from './db.mjs';
import { Accounts } from './auth.mjs';
import { Quota } from './quota.mjs';
import { Tasks, TERMINAL } from './tasks.mjs';
import { Purchases } from './apple.mjs';
import { MICRO_PER_POINT } from './plans.mjs';

const MAX_JSON = 4 * 1024 * 1024, MAX_AVATAR = 600 * 1024;
const MAC_DIR = new URL('../../public/mac/', import.meta.url);
const INSTALL_TEMPLATE = new URL('./mac-install.sh', import.meta.url);
const MAC_FILES = { 'italk-agent.tgz': 'application/gzip', 'italk-agent.tgz.sha256': 'text/plain; charset=utf-8', 'version.json': 'application/json; charset=utf-8' };
const VERSION = '2.0.0';

async function readBody(req, limit) {
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > limit) throw new GatewayError('request_too_large', 413); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
async function readJson(req, limit = MAX_JSON) {
  if (!String(req.headers['content-type'] ?? '').startsWith('application/json')) throw new GatewayError('unsupported_media_type', 415);
  const raw = await readBody(req, limit);
  try { const v = JSON.parse(raw.toString('utf8')); if (v === null || typeof v !== 'object') throw 0; return v; } catch { throw new GatewayError('invalid_json'); }
}
const send = (res, status, body, headers = {}) => {
  if (res.headersSent) return;
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers });
  res.end(body === undefined ? '' : JSON.stringify(body));
};

/**
 * Wires the services to HTTP. `provider` is any object with `generate()` (the DeepSeek/OpenAI-compatible adapter, or a fake in tests).
 * Provider credentials live only in this process's environment; they are never part of a response.
 */
/** What a computer's credential may call: its own model tasks, the subscription summary, signing itself out. */
const AGENT_ALLOWED = [
  ['GET', /^\/v2\/account$/], ['POST', /^\/v2\/auth\/logout$/], ['POST', /^\/v2\/tasks$/], ['GET', /^\/v2\/tasks\/[\w-]{8,64}$/],
  ['GET', /^\/v2\/tasks\/[\w-]{8,64}\/(stream|events)$/], ['POST', /^\/v2\/tasks\/[\w-]{8,64}\/cancel$/],
];
const agentMayCall = (method, path) => AGENT_ALLOWED.some(([m, re]) => m === method && re.test(path));

export function createApp({ db, pricing, provider, mailer = null, appleSignIn = null, verifier = null, now = () => Date.now(), environment = 'development',
                            accountsOptions = {}, retentionMs = 24 * 3_600_000, trustProxy = false, publicUrl = null, macDir = MAC_DIR, tls = null, log = () => {} }) {
  const accounts = new Accounts(db, { now, mailer, appleSignIn, ...accountsOptions });
  const quota = new Quota(db, pricing, { now });
  const tasks = new Tasks({ db, quota, pricing, provider, now, retentionMs, log });
  const purchases = new Purchases({ db, pricing, verifier, now });
  tasks.recover();

  const capabilities = () => ({
    environment, registration: true, passwordReset: Boolean(mailer), emailVerification: Boolean(mailer), signInWithApple: Boolean(appleSignIn),
    subscriptions: purchases.available, taskRetentionHours: Math.round(retentionMs / 3_600_000), version: VERSION,
  });
  const modelList = (available) => Object.entries(pricing.pricing.models).map(([id, m]) => ({
    id, name: m.name, developer: m.developer, usageWeight: pricing.usageWeight(id), contextTokens: m.contextTokens, supportsTools: m.tools, supportsReasoning: m.reasoning,
    supportsImages: m.images, available: available && Boolean(provider), ...(m.note ? { note: m.note } : {}),
  }));
  const planList = () => pricing.plans.map(p => ({ productId: p.productId, tier: p.tier, period: p.period, name: p.name, periodPoints: p.periodPoints, weeklyPoints: p.weeklyPoints, concurrency: p.concurrency, models: p.models }));

  function authenticate(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    const auth = m && accounts.authenticate(m[1]);
    if (!auth) throw new GatewayError('unauthorized', 401);
    return auth;
  }
  const ipOf = (req) => (trustProxy && String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim()) || req.socket.remoteAddress || '';
  const device = (body) => (body?.device && typeof body.device === 'object' ? { name: body.device.name, platform: body.device.platform } : {});

  // ---------- Server-Sent Events: replay after `after`, then live, then close after the terminal event ----------
  function stream(req, res, accountId, id, url) {
    const task = tasks.get(accountId, id);                                   // 404 for other people's tasks
    const header = Number(req.headers['last-event-id']), param = Number(url.searchParams.get('after'));
    let last = Number.isSafeInteger(header) && header >= 0 ? header : (Number.isSafeInteger(param) && param >= 0 ? param : 0);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write(`retry: 2000\n\n`);
    let closed = false, replaying = true;
    const buffered = [];
    const close = () => { if (closed) return; closed = true; clearInterval(beat); unsubscribe(); res.end(); };
    const write = (e) => {
      if (closed || e.seq <= last) return;
      last = e.seq;
      res.write(`id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify(e.data)}\n\n`);
      if (TERMINAL.has(e.type)) close();
    };
    const unsubscribe = tasks.subscribe(id, (e) => (replaying ? buffered.push(e) : write(e)));      // attach first: no gap between replay and live
    const beat = setInterval(() => { if (!closed) res.write(': keep-alive\n\n'); }, 15_000);
    beat.unref?.();
    req.on('close', close);
    for (;;) {
      const batch = tasks.events(accountId, id, last, 1000);
      for (const e of batch) write(e);
      if (batch.length < 1000) break;
    }
    replaying = false;
    buffered.sort((a, b) => a.seq - b.seq).forEach(write);
    const current = tasks.get(accountId, id);
    if (!closed && TERMINAL.has(current.state) && last >= current.lastSeq) close();
  }

  /** The address a Mac should download from: the configured public URL, or (only for a loopback development gateway) the address it was reached at. */
  function gatewayAddress(req) {
    const wanted = publicUrl ?? (/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(req.headers.host ?? '') ? `http://${req.headers.host}` : null);
    return wanted && /^https?:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(wanted.replace(/\/+$/, '')) ? wanted.replace(/\/+$/, '') : null;
  }

  /** The Mac side of iTalk: a one-line installer and the program it installs. Public (nothing secret in it); the program is checked against its checksum. */
  function serveMac(req, res, path) {
    if (path === '/mac/install.sh') {
      const gateway = gatewayAddress(req);
      if (!gateway) throw new GatewayError('feature_unavailable', 503, 'PUBLIC_URL is not configured');
      const script = readFileSync(INSTALL_TEMPLATE, 'utf8').replaceAll('__GATEWAY__', gateway);
      res.writeHead(200, { 'content-type': 'text/x-shellscript; charset=utf-8', 'cache-control': 'no-cache', 'content-length': Buffer.byteLength(script) });
      return void res.end(script);
    }
    const name = path.slice('/mac/'.length), type = MAC_FILES[name];
    const file = type && new URL(name, macDir);
    if (!file || !existsSync(file)) throw new GatewayError('feature_unavailable', 503, 'the Mac program has not been built (node scripts/package-mac-companion.mjs)');
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-cache', 'content-length': statSync(file).size });
    createReadStream(file).pipe(res);
  }

  async function route(req, res) {
    const url = new URL(req.url, 'http://gateway');
    const path = url.pathname.replace(/\/+$/, '') || '/', method = req.method;
    const m = (re) => re.exec(path);
    // ---- public ----
    if (method === 'GET' && /^\/mac\/(install\.sh|italk-agent\.tgz|italk-agent\.tgz\.sha256|version\.json)$/.test(path)) return serveMac(req, res, path);
    if (method === 'GET' && path === '/v2/health') return send(res, 200, { ok: true, version: VERSION, time: now() });
    if (method === 'GET' && path === '/v2/capabilities') return send(res, 200, capabilities());
    if (method === 'GET' && path === '/v2/plans') return send(res, 200, { plans: planList() });
    if (method === 'GET' && path === '/v2/models') return send(res, 200, { models: modelList(true) });
    // ---- authentication ----
    if (method === 'POST' && path === '/v2/auth/register') { const b = await readJson(req, 16_384); return send(res, 201, await accounts.register({ ...b, device: device(b), ip: ipOf(req) })); }
    if (method === 'POST' && path === '/v2/auth/login') { const b = await readJson(req, 16_384); return send(res, 200, await accounts.login({ ...b, device: device(b), ip: ipOf(req) })); }
    if (method === 'POST' && path === '/v2/auth/apple') { const b = await readJson(req, 16_384); return send(res, 200, await accounts.signInWithApple({ ...b, device: device(b) })); }
    if (method === 'POST' && path === '/v2/auth/password-reset/request') { const b = await readJson(req, 4096); await accounts.requestPasswordReset({ email: b.email, ip: ipOf(req) }); return send(res, 202, {}); }
    if (method === 'POST' && path === '/v2/auth/password-reset/confirm') { const b = await readJson(req, 4096); await accounts.confirmPasswordReset({ ...b, ip: ipOf(req) }); return send(res, 204); }
    if (method === 'POST' && path === '/v2/iap/notifications') {                      // called by Apple; authenticity comes from the JWS signature
      const b = await readJson(req, 262_144);
      if (typeof b.signedPayload !== 'string') throw new GatewayError('invalid_arguments');
      return send(res, 200, await purchases.handleNotification(b.signedPayload));
    }
    // ---- everything below needs a session ----
    const auth = authenticate(req);
    const { accountId, sessionId, scope } = auth;
    if (scope === 'agent' && !agentMayCall(method, path)) throw new GatewayError('forbidden_scope', 403);
    if (method === 'POST' && path === '/v2/auth/logout') { accounts.logout(sessionId); return send(res, 204); }
    if (method === 'POST' && path === '/v2/auth/logout-all') { accounts.logoutAll(accountId); return send(res, 204); }
    if (method === 'POST' && path === '/v2/auth/email/verify/request') { await accounts.requestEmailVerification(accountId); return send(res, 202, {}); }
    if (method === 'POST' && path === '/v2/auth/email/verify/confirm') { const b = await readJson(req, 1024); accounts.confirmEmail(accountId, b.code ?? b.token); return send(res, 204); }

    // A computer's credential sees the subscription and the models it may use, never the person's profile.
    if (method === 'GET' && path === '/v2/account' && scope === 'agent') return send(res, 200, { subscription: quota.summary(accountId), models: (quota.entitlement(accountId).plan?.models ?? []) });
    if (method === 'POST' && path === '/v2/agent-sessions') {
      const b = await readJson(req, 2048).catch(() => ({}));
      return send(res, 201, { session: accounts.createAgentSession(accountId, { name: b?.name }) });
    }
    if (method === 'GET' && path === '/v2/account') return send(res, 200, { account: accounts.profile(accountId), subscription: quota.summary(accountId), models: (quota.entitlement(accountId).plan?.models ?? []) });
    if (method === 'PATCH' && path === '/v2/account') { const b = await readJson(req, 4096); return send(res, 200, { account: accounts.updateProfile(accountId, b) }); }
    if (method === 'PUT' && path === '/v2/account/avatar') {
      const bytes = await readBody(req, MAX_AVATAR);
      return send(res, 200, { account: accounts.setAvatar(accountId, bytes) });
    }
    if (method === 'GET' && path === '/v2/account/avatar') {
      const a = accounts.avatar(accountId);
      if (!a) return send(res, 404, { error: { code: 'not_found' } });
      const version = String(accounts.profile(accountId).avatarVersion);
      if (req.headers['if-none-match'] === `"${version}"`) return send(res, 304);
      res.writeHead(200, { 'content-type': a.type, 'cache-control': 'private, max-age=0', etag: `"${version}"`, 'content-length': a.bytes.length });
      return void res.end(a.bytes);
    }
    if (method === 'DELETE' && path === '/v2/account/avatar') { accounts.removeAvatar(accountId); return send(res, 200, { account: accounts.profile(accountId) }); }
    if (method === 'POST' && path === '/v2/account/password') { const b = await readJson(req, 4096); await accounts.changePassword(accountId, b, sessionId); return send(res, 204); }
    if (method === 'GET' && path === '/v2/account/sessions') return send(res, 200, { sessions: accounts.sessions(accountId).map(s => ({ ...s, current: s.id === sessionId })) });
    let mm;
    if (method === 'DELETE' && (mm = m(/^\/v2\/account\/sessions\/([\w-]{8,64})$/))) {
      if (!accounts.sessions(accountId).some(s => s.id === mm[1])) throw new GatewayError('not_found', 404);
      accounts.logout(mm[1]); return send(res, 204);
    }
    if (method === 'DELETE' && path === '/v2/account') { const b = await readJson(req, 4096).catch(() => ({})); await accounts.deleteAccount(accountId, b); return send(res, 204); }
    if (method === 'GET' && path === '/v2/usage') {
      const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit')) || 50));
      const rows = db.prepare("SELECT id, model, state, cost_micro, input_tokens, cached_input_tokens, output_tokens, estimated, created_at FROM usage WHERE account_id=? AND state='settled' ORDER BY created_at DESC LIMIT ?").all(accountId, limit);
      return send(res, 200, { records: rows.map(r => ({ id: r.id, date: r.created_at, model: r.model, points: Math.round(r.cost_micro / MICRO_PER_POINT * 100) / 100, inputTokens: r.input_tokens,
                                                          cachedInputTokens: r.cached_input_tokens, outputTokens: r.output_tokens, estimated: Boolean(r.estimated) })) });
    }
    if (method === 'POST' && path === '/v2/iap/transactions') {
      const b = await readJson(req, 262_144);
      await purchases.attach(accountId, accounts.profile(accountId).appleAccountToken, b.signedTransactions);
      return send(res, 200, { subscription: quota.summary(accountId) });
    }

    // ---- durable tasks ----
    if (method === 'POST' && path === '/v2/tasks') {
      if (!provider) throw new GatewayError('provider_not_configured', 503);
      const body = await readJson(req);
      const ent = quota.entitlement(accountId);
      const { task, created } = tasks.create(accountId, req.headers['idempotency-key'], body, { allowedModels: ent.active ? ent.plan.models : Object.keys(pricing.pricing.models) });
      return send(res, created ? 201 : 200, { task });
    }
    if (method === 'GET' && path === '/v2/tasks') return send(res, 200, { tasks: tasks.list(accountId, { limit: Number(url.searchParams.get('limit')) || 20 }) });
    if ((mm = m(/^\/v2\/tasks\/([\w-]{8,64})(?:\/(stream|events|cancel))?$/))) {
      const [, id, action] = mm;
      if (!action && method === 'GET') return send(res, 200, { task: tasks.get(accountId, id) });
      if (action === 'cancel' && method === 'POST') return send(res, 200, { task: tasks.cancel(accountId, id) });
      if (action === 'events' && method === 'GET') {
        const after = Math.max(0, Number(url.searchParams.get('after')) || 0), limit = Math.min(500, Math.max(1, Number(url.searchParams.get('limit')) || 500));
        return send(res, 200, { events: tasks.events(accountId, id, after, limit), task: tasks.get(accountId, id) });
      }
      if (action === 'stream' && method === 'GET') return stream(req, res, accountId, id, url);
    }
    throw new GatewayError('not_found', 404);
  }

  const handler = async (req, res) => {
    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: inferred
    // Why: Development phones may fail before authentication when testing a pinned LAN gateway.
    // Debug Goal: Observe only the public capability probe and account request, without logging credentials or message bodies.
    // Search Tags: developer gateway phone local network connection diagnostics
    // Invariants:
    // - Production and other routes do not use this diagnostic.
    // - Session tokens, request bodies and IP addresses are never logged.
    // Failure Modes:
    // - A healthy Mac listener alone does not prove the phone can reach it.
    // - Logging request headers would expose bearer credentials.
    if (environment === 'development' && ['GET /v2/capabilities', 'GET /v2/account'].includes(`${req.method} ${req.url?.split('?')[0]}`)) {
      const path = req.url.split('?')[0];
      res.once('finish', () => log('dev_connection_check', { path, status: res.statusCode }));
    }
    res.setHeader('X-Content-Type-Options', 'nosniff');
    try { await route(req, res); }
    catch (error) {
      if (error instanceof GatewayError) {
        log('request_error', { code: error.code, status: error.status, path: req.url?.split('?')[0] });
        return send(res, error.status, { error: { code: error.code, message: error.code.replaceAll('_', ' '), ...(error.detail ? { detail: error.detail } : {}) } });
      }
      log('internal_error', { message: String(error?.message ?? error).slice(0, 200), path: req.url?.split('?')[0] });
      send(res, 500, { error: { code: 'internal_error', message: 'internal error' } });
    }
  };
  const server = tls ? https.createServer({ ...tls, minVersion: 'TLSv1.2' }, handler) : http.createServer(handler);
  server.requestTimeout = 0;           // SSE streams are long-lived; bodies are bounded by the readers above
  server.headersTimeout = 30_000;

  const timers = [
    setInterval(() => { try { quota.reconcile(); } catch (e) { log('reconcile_error', { message: String(e?.message) }); } }, 60_000),
    setInterval(() => { try { tasks.purge(); db.prepare('DELETE FROM rate_events WHERE at<?').run(now() - 24 * 3_600_000); } catch (e) { log('purge_error', { message: String(e?.message) }); } }, 3_600_000),
  ];
  timers.forEach(t => t.unref?.());
  return { server, accounts, quota, tasks, purchases, close: async () => { timers.forEach(clearInterval); await new Promise(r => server.close(r)); } };
}
