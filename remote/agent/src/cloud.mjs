import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, chmodSync, mkdirSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { parseSSE } from './sse.mjs';

// Managed cloud model access uses the scoped iTalk account session supplied by the paired phone.
// Computer-local Ollama access is separate and never needs or receives this credential.

export class CloudError extends Error {
  constructor(code, message, { status, retryable = false, retryAfterMs, fallback = false, detail } = {}) {
    super(message ?? code); this.code = code; this.status = status; this.retryable = retryable; this.retryAfterMs = retryAfterMs; this.fallback = fallback; this.detail = detail;
  }
}

const KEYCHAIN_SERVICE = 'iTalk Agent', KEYCHAIN_ACCOUNT = 'cloud-credential';

/** https only, except the computer's own loopback address (development gateways). No credentials, queries or fragments in the URL. */
export function normalizeGateway(value) {
  let u;
  try { u = new URL(String(value)); } catch { throw new CloudError('invalid_gateway', 'The gateway address is not a URL.'); }
  const loopback = ['127.0.0.1', 'localhost', '[::1]', '::1'].includes(u.hostname);
  if (!(u.protocol === 'https:' || (u.protocol === 'http:' && loopback))) throw new CloudError('invalid_gateway', 'The gateway must use https.');
  if (u.username || u.password || u.search || u.hash) throw new CloudError('invalid_gateway', 'The gateway address must be a plain URL.');
  return u.toString().replace(/\/+$/, '');
}

export const macKeychain = {
  read() { try { return execFileSync('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-a', KEYCHAIN_ACCOUNT, '-w'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null; } catch { return null; } },
  write(secret) { execFileSync('security', ['add-generic-password', '-U', '-s', KEYCHAIN_SERVICE, '-a', KEYCHAIN_ACCOUNT, '-w', secret], { stdio: 'ignore', timeout: 10_000 }); },
  remove() { try { execFileSync('security', ['delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', KEYCHAIN_ACCOUNT], { stdio: 'ignore', timeout: 5000 }); } catch {} },
};

/** Where model access is kept: the secret in the login Keychain (a 0600 file when the Keychain is unavailable), the rest in `cloud.json`. */
export class CloudAccess {
  constructor({ stateDir, keychain = macKeychain, fetcher = fetch, now = () => Date.now() }) {
    Object.assign(this, { stateDir, keychain, fetcher, now });
    this.file = path.join(stateDir, 'cloud.json'); this.secretFile = path.join(stateDir, 'cloud.secret');
    this.cache = undefined;
  }
  load() {
    if (this.cache !== undefined) return this.cache;
    let meta = null;
    try { meta = existsSync(this.file) ? JSON.parse(readFileSync(this.file, 'utf8')) : null; } catch { meta = null; }
    if (!meta?.gateway) return (this.cache = null);
    let token = null;
    try { token = this.keychain.read(); } catch {}
    if (!token && existsSync(this.secretFile)) { try { token = readFileSync(this.secretFile, 'utf8').trim() || null; } catch {} }
    return (this.cache = token ? { ...meta, token } : null);
  }
  get configured() { return Boolean(this.load()); }
  /** What the phone may be told about the stored access (never the token). */
  describe() {
    const a = this.load();
    return a ? { configured: true, gateway: a.gateway, issuedAt: a.issuedAt, expiresAt: a.expiresAt, accountHint: a.accountHint ?? null, sessionName: a.sessionName ?? null } : { configured: false };
  }
  save({ gateway, token, expiresAt, accountHint, sessionName }) {
    const url = normalizeGateway(gateway);
    if (typeof token !== 'string' || token.length < 20 || token.length > 200 || /\s/.test(token)) throw new CloudError('invalid_token', 'The credential is malformed.');
    mkdirSync(this.stateDir, { recursive: true, mode: 0o700 });
    let stored = 'keychain';
    try { this.keychain.write(token); try { unlinkSync(this.secretFile); } catch {} }
    catch { writeFileSync(this.secretFile, token + '\n', { mode: 0o600 }); chmodSync(this.secretFile, 0o600); stored = 'file'; }
    writeFileSync(this.file, JSON.stringify({ gateway: url, issuedAt: this.now(), expiresAt: expiresAt ?? null, accountHint: accountHint ?? null, sessionName: sessionName ?? null, stored }, null, 2) + '\n', { mode: 0o600 });
    chmodSync(this.file, 0o600);
    this.cache = undefined;
  }
  clear() {
    try { this.keychain.remove(); } catch {}
    for (const f of [this.file, this.secretFile]) try { unlinkSync(f); } catch {}
    this.cache = undefined;
  }

  /** Forgets the credential and, best effort, asks the gateway to revoke it, so a computer that was removed cannot keep using the account.
   *  Without a reachable gateway the credential is still forgotten here; it then stays listed as "Mac · name" in the account's devices until it expires or the person signs it out. */
  async revoke({ timeoutMs = 5000 } = {}) {
    const access = this.load();
    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: verified
    // Why: Gateway logout may finish after another phone supplies new access.
    // Debug Goal: Remove only the credential being revoked.
    // Search Tags: cloud credential revoke race new login
    // Invariants:
    // - Clear the old local credential before waiting for the network.
    // - Never clear a replacement credential when logout completes.
    // Failure Modes:
    // - A slow logout erases a newly provisioned credential.
    this.clear();
    let revoked = false;
    if (access) {
      try {
        const r = await this.fetcher(`${access.gateway}/v2/auth/logout`, { method: 'POST', headers: { authorization: `Bearer ${access.token}` }, signal: AbortSignal.timeout(timeoutMs) });
        revoked = r.status === 200 || r.status === 204 || r.status === 401;     // 401: the gateway had already dropped it
      } catch {}
    }
    return { revoked };
  }

  /** A real round trip: is the credential accepted, is there a subscription, which models may this account use, how fast is the gateway. */
  async verify({ signal } = {}) {
    const access = this.load();
    if (!access) return { ok: false, code: 'cloud_not_configured', message: 'This computer has not received model access from the iPhone yet.' };
    const started = this.now();
    try {
      const [account, models] = await Promise.all([
        this.fetcher(`${access.gateway}/v2/account`, { headers: { authorization: `Bearer ${access.token}` }, signal: signal ?? AbortSignal.timeout(15_000) }),
        this.fetcher(`${access.gateway}/v2/models`, { signal: signal ?? AbortSignal.timeout(15_000) }),
      ]);
      if (account.status === 401) return { ok: false, code: 'cloud_auth', message: 'The credential was rejected. Set this computer up again from the iPhone.' };
      if (!account.ok) return { ok: false, code: 'cloud_error', message: `The iTalk service answered ${account.status}.` };
      const a = await account.json(), m = models.ok ? await models.json() : { models: [] };
      const allowed = new Set(a.models ?? []);
      const usable = (m.models ?? []).filter(x => x.available !== false && allowed.has(x.id));
      const subscription = a.subscription ?? { status: 'none' };
      const active = ['active', 'grace', 'billing_retry'].includes(subscription.status);
      return { ok: active && usable.length > 0, code: active ? (usable.length ? null : 'model_not_in_plan') : 'subscription_required',
               message: active ? (usable.length ? 'Ready.' : 'The plan has no model this computer can use.') : 'An active iTalk subscription is needed.',
               subscription: { status: subscription.status, tier: subscription.tier ?? null, planName: subscription.planName ?? null, periodEnd: subscription.periodEnd ?? null, windows: subscription.windows ?? null },
               models: usable.map(x => ({ id: x.id, name: x.name, developer: x.developer, contextTokens: x.contextTokens, supportsTools: x.supportsTools, supportsReasoning: x.supportsReasoning, supportsImages: x.supportsImages, usageWeight: x.usageWeight })),
               latencyMs: this.now() - started };
    } catch (error) {
      return { ok: false, code: 'cloud_unreachable', message: 'Cannot reach the iTalk service from this computer.', detail: String(error?.message ?? error).slice(0, 120) };
    }
  }
}

/** Jittered exponential backoff: min(base·2^(attempt-1), max) plus up to 50 % jitter. `attempt` starts at 1. */
export function backoffMs(attempt, { base = 1000, max = 30_000, random = Math.random } = {}) {
  const delay = Math.min(base * 2 ** Math.max(0, attempt - 1), max);
  return Math.round(delay + random() * delay * 0.5);
}

/** HTTP answer of the gateway → what to do about it. Codes are the gateway's own stable strings; nothing is matched in free text. */
export function classifyGatewayError(status, body, headers) {
  const code = body?.error?.code ?? null, detail = body?.error?.detail ?? null;
  const retryAfter = Number(headers?.get?.('retry-after'));
  const retryAfterMs = Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter, 120) * 1000 : undefined;
  if (status === 401) return new CloudError('cloud_auth', 'The iTalk credential on this computer was rejected. Set the computer up again from the iPhone.', { status });
  if (status === 402 || code === 'subscription_required') return new CloudError('subscription_required', 'An active iTalk subscription is needed.', { status, detail });
  if (code === 'quota_exceeded') return new CloudError('quota_exceeded', 'The usage allowance of this subscription is used up for now.', { status, detail });
  if (code === 'too_many_concurrent_requests' || code === 'too_many_attempts') return new CloudError('concurrency_limited', 'The account is already running its maximum number of model requests.', { status, retryable: true, retryAfterMs: retryAfterMs ?? 3000, detail });
  if (code === 'model_not_in_plan' || code === 'model_not_available') return new CloudError('model_not_in_plan', 'This model is not part of the current plan.', { status, fallback: true, detail });
  if (code === 'idempotency_conflict') return new CloudError('idempotency_conflict', 'The step was already submitted with different content.', { status });
  if (code === 'invalid_arguments') return new CloudError('bad_request', `The request was refused: ${detail ?? 'invalid arguments'}`, { status, detail });
  if (status === 429) return new CloudError('rate_limited', 'The iTalk service asked to slow down.', { status, retryable: true, retryAfterMs: retryAfterMs ?? 5000 });
  if (status >= 500) return new CloudError('cloud_error', 'The iTalk service had a problem.', { status, retryable: true, retryAfterMs, fallback: true, detail: code });
  return new CloudError('cloud_error', `The iTalk service answered ${status}.`, { status, detail: code });
}

const TERMINAL = new Set(['completed', 'failed', 'cancelled']);

/**
 * One model step through the gateway's durable tasks. The step is identified by an idempotency key, so a retry after a dropped
 * connection (or a restart of this program) continues the same step instead of paying for a second generation, and the event stream is
 * resumed from the last event applied. Retries, waits and fallbacks are reported to the person through `onStatus`.
 */
export class GatewayModelClient {
  constructor({ access, fetcher = fetch, sleep = (ms, signal) => new Promise((resolve, reject) => { const t = setTimeout(resolve, ms); signal?.addEventListener('abort', () => { clearTimeout(t); reject(Object.assign(new Error('aborted'), { name: 'AbortError' })); }, { once: true }); }),
                maxSubmitAttempts = 6, maxReconnects = 12, random = Math.random, log = () => {} }) {
    Object.assign(this, { access, fetcher, sleep, maxSubmitAttempts, maxReconnects, random, log });
  }

  #headers(access, extra = {}) { return { authorization: `Bearer ${access.token}`, ...extra }; }

  async step({ model, fallbackModels = [], messages, tools, maxTokens = 2000, reasoningEffort = 'none', idempotencyKey, runId, step, signal, onText, onReasoning, onStatus = () => {} }) {
    const chain = [model, ...fallbackModels.filter(m => m && m !== model)];
    let lastError;
    for (let i = 0; i < chain.length; i++) {
      try {
        const key = i === 0 ? idempotencyKey : `${idempotencyKey}~m${i}`;
        return { ...(await this.#stepWith({ model: chain[i], messages, tools, maxTokens, reasoningEffort, idempotencyKey: key, runId, step, signal, onText, onReasoning, onStatus })), model: chain[i] };
      } catch (error) {
        if (signal?.aborted) throw error;
        lastError = error;
        if (error instanceof CloudError && error.fallback && i + 1 < chain.length) { onStatus(`Switching to ${chain[i + 1]}: ${chain[i]} is not available right now.`); continue; }
        throw error;
      }
    }
    throw lastError;
  }

  async #stepWith({ model, messages, tools, maxTokens, reasoningEffort, idempotencyKey, runId, step, signal, onText, onReasoning, onStatus }) {
    const body = JSON.stringify({ model, messages, tools, maxTokens, reasoningEffort, ...(runId ? { runId } : {}), ...(Number.isSafeInteger(step) ? { step } : {}) });
    let resubmits = 0, key = idempotencyKey;
    for (;;) {
      const taskId = await this.#submit({ body, key, signal, onStatus });
      try { return await this.#read({ taskId, signal, onText, onReasoning, onStatus }); }
      catch (error) {
        // The gateway restarted mid-step, or the provider dropped it: the step produced a (partial) failed task; submit it again under a new key.
        if (error instanceof CloudError && error.code === 'step_interrupted' && resubmits < 2) { resubmits += 1; key = `${idempotencyKey}~r${resubmits}`; onStatus('The model connection was interrupted; trying that step again.'); continue; }
        throw error;
      }
    }
  }

  async #submit({ body, key, signal, onStatus }) {
    let attempt = 0;
    for (;;) {
      attempt += 1;
      const access = this.access.load();
      if (!access) throw new CloudError('cloud_not_configured', 'This computer has not received model access from the iPhone yet.');
      let response;
      try { response = await this.fetcher(`${access.gateway}/v2/tasks`, { method: 'POST', headers: this.#headers(access, { 'content-type': 'application/json', 'idempotency-key': key }), body, signal }); }
      catch (error) {
        if (signal?.aborted) throw error;
        if (attempt >= this.maxSubmitAttempts) throw new CloudError('cloud_unreachable', 'Cannot reach the iTalk service.', { retryable: true });
        const wait = backoffMs(attempt, { random: this.random });
        onStatus(`Cannot reach the iTalk service; retrying in ${Math.ceil(wait / 1000)} s.`); await this.sleep(wait, signal); continue;
      }
      if (response.ok) { const json = await response.json(); return json.task.id; }
      const parsed = await response.json().catch(() => null);
      const error = classifyGatewayError(response.status, parsed, response.headers);
      if (error.retryable && attempt < this.maxSubmitAttempts) {
        const wait = error.retryAfterMs ?? backoffMs(attempt, { random: this.random });
        onStatus(`${error.message} Retrying in ${Math.ceil(wait / 1000)} s.`); await this.sleep(wait, signal); continue;
      }
      throw error;
    }
  }

  async #read({ taskId, signal, onText, onReasoning, onStatus }) {
    let last = 0, reconnects = 0, text = '', reasoning = '', usage = null, finish = null;
    const calls = [];
    for (;;) {
      const access = this.access.load();
      if (!access) throw new CloudError('cloud_not_configured', 'This computer has not received model access from the iPhone yet.');
      let terminal = null;
      try {
        const response = await this.fetcher(`${access.gateway}/v2/tasks/${taskId}/stream?after=${last}`, { headers: this.#headers(access, { 'last-event-id': String(last), accept: 'text/event-stream' }), signal });
        if (!response.ok || !response.body) {
          const parsed = await response.json().catch(() => null);
          throw classifyGatewayError(response.status, parsed, response.headers);
        }
        for await (const event of parseSSE(response.body, signal)) {
          const seq = Number(event.__sse?.id), type = event.__sse?.event;
          if (Number.isFinite(seq)) { if (seq <= last) continue; last = seq; }
          if (type === 'delta') { text += event.text ?? ''; onText?.(event.text ?? ''); }
          else if (type === 'reasoning') { reasoning += event.text ?? ''; onReasoning?.(event.text ?? ''); }
          else if (type === 'tool_call') calls.push({ id: event.id, name: event.name, arguments: typeof event.arguments === 'string' ? event.arguments : JSON.stringify(event.arguments ?? {}) });
          else if (type === 'usage') usage = { inputTokens: event.inputTokens ?? 0, cachedInputTokens: event.cachedInputTokens ?? 0, outputTokens: event.outputTokens ?? 0, reasoningTokens: event.reasoningTokens ?? 0 };
          else if (TERMINAL.has(type)) { terminal = { type, ...event }; break; }
        }
      } catch (error) {
        // A stop requested by the person cancels the step at the gateway (nothing more is generated or billed); a restart of this program
        // leaves it running so the same step can be picked up again.
        if (signal?.aborted) { if (signal.reason?.code !== 'shutdown') this.#cancel(taskId, access).catch(() => {}); throw error; }
        if (error instanceof CloudError && !error.retryable) throw error;
        reconnects += 1;
        if (reconnects > this.maxReconnects) throw new CloudError('cloud_stream_interrupted', 'The connection to the iTalk service kept dropping.', { retryable: true });
        const wait = backoffMs(reconnects, { base: 500, max: 15_000, random: this.random });
        onStatus(`The connection dropped; reconnecting in ${Math.ceil(wait / 1000)} s and continuing from where it stopped.`);
        await this.sleep(wait, signal); continue;
      }
      if (!terminal) {
        // The stream ended without a terminal event (proxy timeout): ask for the rest.
        reconnects += 1;
        if (reconnects > this.maxReconnects) throw new CloudError('cloud_stream_interrupted', 'The connection to the iTalk service kept dropping.', { retryable: true });
        await this.sleep(backoffMs(reconnects, { base: 300, max: 5000, random: this.random }), signal); continue;
      }
      if (terminal.type === 'cancelled') throw Object.assign(new Error('aborted'), { name: 'AbortError' });
      if (terminal.type === 'failed') {
        const code = terminal.code ?? 'provider_error';
        if (code === 'interrupted') throw new CloudError('step_interrupted', 'The iTalk service restarted while answering.', { retryable: true });
        if (code === 'quota_exceeded') throw new CloudError('quota_exceeded', 'The usage allowance of this subscription is used up for now.');
        throw new CloudError('cloud_error', `The model could not finish (${code}).`, { retryable: true, fallback: true, detail: code });
      }
      finish = terminal.finishReason ?? (calls.length ? 'toolCalls' : 'stop');
      return { text, reasoning, toolCalls: calls, usage, finish };
    }
  }

  async #cancel(taskId, access) { await this.fetcher(`${access.gateway}/v2/tasks/${taskId}/cancel`, { method: 'POST', headers: this.#headers(access), signal: AbortSignal.timeout(5000) }); }
}
