import { randomUUID, createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { GatewayError, tx } from './db.mjs';
import { estimateTokens } from './plans.mjs';

// Durable model steps.
//
// A task is one model step of an agent run: the phone sends the messages and tool schemas, the gateway streams the model's answer
// into an ordered, persisted event log, and the phone reads that log over any number of connections. Execution never belongs to a
// connection: closing the app, a phone call, a network switch or a dropped socket only ends a *reader*. A reader that comes back asks
// for "events after N" and continues exactly where it stopped (the Server-Sent Events `Last-Event-ID` contract).
//
// Event types (payload JSON): reasoning{text} delta{text} tool_call{id,name,arguments} usage{…} and exactly one terminal event:
// completed{finishReason} | failed{code} | cancelled{}. `seq` starts at 1 and has no gaps.

export const TERMINAL = new Set(['completed', 'failed', 'cancelled']);
const COALESCE_MS = 80, COALESCE_CHARS = 600;

const digestOf = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export function validateTaskRequest(body, { allowedModels }) {
  const fail = (detail) => { throw new GatewayError('invalid_arguments', 400, detail); };
  if (!body || typeof body !== 'object') fail('body');
  const allowed = ['model', 'messages', 'tools', 'maxTokens', 'images', 'reasoningEffort', 'runId', 'step', 'title'];
  for (const k of Object.keys(body)) if (!allowed.includes(k)) fail(`unknown field ${k}`);
  if (typeof body.model !== 'string' || !allowedModels.includes(body.model)) throw new GatewayError('model_not_available', 400);
  if (!Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > 200) fail('messages');
  const roles = new Set(['system', 'user', 'assistant', 'tool']);
  for (const m of body.messages) {
    if (!m || !roles.has(m.role) || typeof m.text !== 'string' || m.text.length > 60000) fail('message');
    if (m.toolCalls !== undefined && (!Array.isArray(m.toolCalls) || m.toolCalls.length > 8 || m.toolCalls.some(c => typeof c.id !== 'string' || typeof c.name !== 'string' || typeof c.arguments !== 'string'))) fail('toolCalls');
    if (m.reasoningContent !== undefined && (typeof m.reasoningContent !== 'string' || m.reasoningContent.length > 40000)) fail('reasoningContent');
  }
  const tools = body.tools ?? [];
  if (!Array.isArray(tools) || tools.length > 64) fail('tools');
  for (const t of tools) if (!t || !/^[a-z][a-z0-9_]{0,63}$/.test(t.name) || typeof t.description !== 'string' || t.description.length > 2000 || typeof t.parameters !== 'object') fail('tool');
  const maxTokens = body.maxTokens ?? 800;
  if (!Number.isSafeInteger(maxTokens) || maxTokens < 1 || maxTokens > 4000) fail('maxTokens');
  const effort = body.reasoningEffort ?? 'none';
  if (!['none', 'low', 'high', 'max'].includes(effort)) fail('reasoningEffort');
  const images = body.images ?? [];
  if (!Array.isArray(images) || images.length > 3 || images.some(i => i?.mimeType !== 'image/jpeg' || typeof i?.data !== 'string' || i.data.length > 1_400_000)) fail('images');
  return { model: body.model, messages: body.messages, tools, maxTokens, images, reasoningEffort: effort, runId: typeof body.runId === 'string' ? body.runId.slice(0, 64) : null, step: Number.isSafeInteger(body.step) ? body.step : null };
}

export class Tasks extends EventEmitter {
  constructor({ db, quota, pricing, provider, now = () => Date.now(), retentionMs = 24 * 3_600_000, onTerminal = () => {}, log = () => {} }) {
    super();
    Object.assign(this, { db, quota, pricing, provider, now, retentionMs, onTerminal, log });
    this.setMaxListeners(0);
    this.running = new Map();      // taskId → { abort, done: Promise }
  }

  // ---------- submission ----------
  /** Idempotent: the same Idempotency-Key with the same request returns the existing task and never bills twice. */
  create(accountId, idemKey, rawBody, { allowedModels }) {
    if (typeof idemKey !== 'string' || idemKey.length < 8 || idemKey.length > 100) throw new GatewayError('idempotency_key_required', 400);
    const request = validateTaskRequest(rawBody, { allowedModels });
    const digest = digestOf({ ...request, images: request.images.length });
    const existing = this.db.prepare('SELECT * FROM tasks WHERE account_id=? AND idem_key=?').get(accountId, idemKey);
    if (existing) {
      if (existing.request_digest !== digest) throw new GatewayError('idempotency_conflict', 409);
      return { task: this.snapshot(existing), created: false };
    }
    const inputTokens = estimateTokens(JSON.stringify(request.messages)) + estimateTokens(JSON.stringify(request.tools)) + request.images.length * 800;
    const maxOutput = request.maxTokens + (request.reasoningEffort === 'none' ? 0 : 2048);
    const hold = this.pricing.maxCostMicro(request.model, { inputTokens, maxOutput });
    const id = randomUUID();
    const usageId = this.quota.reserve(accountId, { model: request.model, maxCostMicro: hold, taskId: id });   // throws before anything is stored or sent
    try {
      tx(this.db, () => this.db.prepare("INSERT INTO tasks(id,account_id,idem_key,request_digest,state,model,run_id,step,request_json,created_at) VALUES(?,?,?,?, 'queued', ?,?,?,?,?)")
        .run(id, accountId, idemKey, digest, request.model, request.runId, request.step, JSON.stringify(request), this.now()));
    } catch (error) { this.quota.release(usageId); throw error; }
    this.db.prepare('UPDATE usage SET task_id=? WHERE id=?').run(id, usageId);
    this.start(id, usageId, request);
    return { task: this.snapshot(this.db.prepare('SELECT * FROM tasks WHERE id=?').get(id)), created: true };
  }

  snapshot(row) {
    const usage = this.db.prepare('SELECT state, cost_micro, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, estimated FROM usage WHERE task_id=?').get(row.id);
    return { id: row.id, state: row.state, model: row.model, runId: row.run_id, step: row.step, createdAt: row.created_at, finishedAt: row.finished_at,
             lastSeq: row.last_seq, finishReason: row.finish_reason, error: row.error_code,
             usage: usage && usage.state === 'settled' ? { inputTokens: usage.input_tokens, cachedInputTokens: usage.cached_input_tokens, outputTokens: usage.output_tokens, reasoningTokens: usage.reasoning_tokens, estimated: Boolean(usage.estimated) } : null };
  }
  get(accountId, id) {
    const row = this.db.prepare('SELECT * FROM tasks WHERE id=? AND account_id=?').get(id, accountId);
    if (!row) throw new GatewayError('task_not_found', 404);
    return this.snapshot(row);
  }
  list(accountId, { limit = 20 } = {}) {
    return this.db.prepare('SELECT * FROM tasks WHERE account_id=? ORDER BY created_at DESC LIMIT ?').all(accountId, Math.min(limit, 100)).map(r => this.snapshot(r));
  }

  // ---------- event log ----------
  events(accountId, id, after = 0, limit = 500) {
    if (!this.db.prepare('SELECT 1 FROM tasks WHERE id=? AND account_id=?').get(id, accountId)) throw new GatewayError('task_not_found', 404);
    return this.db.prepare('SELECT seq, type, payload, created_at AS at FROM task_events WHERE task_id=? AND seq>? ORDER BY seq LIMIT ?').all(id, after, limit)
      .map(e => ({ seq: e.seq, type: e.type, data: JSON.parse(e.payload), at: e.at }));
  }

  append(taskId, type, data) {
    const seq = tx(this.db, () => {
      const row = this.db.prepare('SELECT last_seq FROM tasks WHERE id=?').get(taskId);
      if (!row) return null;
      const next = row.last_seq + 1;
      this.db.prepare('INSERT INTO task_events(task_id,seq,type,payload,created_at) VALUES(?,?,?,?,?)').run(taskId, next, type, JSON.stringify(data ?? {}), this.now());
      this.db.prepare('UPDATE tasks SET last_seq=? WHERE id=?').run(next, taskId);
      return next;
    });
    if (seq) this.emit(`task:${taskId}`, { seq, type, data: data ?? {} });
    return seq;
  }

  /** Subscribes to live events of one task. The caller replays stored events first, then attaches this, de-duplicating by seq. */
  subscribe(taskId, listener) { this.on(`task:${taskId}`, listener); return () => this.off(`task:${taskId}`, listener); }

  // ---------- execution ----------
  start(taskId, usageId, request) {
    const abort = new AbortController();
    const done = this.execute(taskId, usageId, request, abort).catch(error => this.log('task_error', { taskId, code: error?.code ?? 'internal' })).finally(() => this.running.delete(taskId));
    this.running.set(taskId, { abort, done });
  }

  async execute(taskId, usageId, request, abort) {
    this.db.prepare("UPDATE tasks SET state='running', started_at=? WHERE id=? AND state='queued'").run(this.now(), taskId);
    this.append(taskId, 'started', { model: request.model });
    let buffer = { type: null, text: '' }, timer = null, delivered = 0, usage = null, finish = 'stop';
    const flush = () => { clearTimeout(timer); timer = null; if (buffer.text) { this.append(taskId, buffer.type, { text: buffer.text }); } buffer = { type: null, text: '' }; };
    const buffered = (type, text) => {
      if (buffer.type && buffer.type !== type) flush();
      buffer.type = type; buffer.text += text; delivered += text.length;
      if (buffer.text.length >= COALESCE_CHARS) flush(); else if (!timer) timer = setTimeout(flush, COALESCE_MS);
    };
    let terminal;
    try {
      const stream = this.provider.generate({ model: request.model, messages: request.messages, tools: request.tools, maxTokens: request.maxTokens, images: request.images,
                                              reasoning: request.reasoningEffort !== 'none', reasoningEffort: request.reasoningEffort, signal: abort.signal });
      for await (const event of stream) {
        if (abort.signal.aborted) break;
        if (event.type === 'delta') buffered('delta', event.text);
        else if (event.type === 'reasoning') buffered('reasoning', event.text);
        else if (event.type === 'tool_call') { flush(); delivered += 1; this.append(taskId, 'tool_call', { id: event.id, name: event.name, arguments: event.arguments }); }
        else if (event.type === 'usage') usage = event;
        else if (event.type === 'finish') finish = event.reason;
      }
      flush();
      if (abort.signal.aborted) terminal = { type: 'cancelled', data: {} };
      else if (!usage) throw new GatewayError('provider_usage_unavailable', 502);
      else terminal = { type: 'completed', data: { finishReason: finish } };
    } catch (error) {
      flush();
      terminal = abort.signal.aborted ? { type: 'cancelled', data: {} } : { type: 'failed', data: { code: error instanceof GatewayError ? error.code : 'provider_error' } };
    }
    // Billing: the provider's usage when it reported one; otherwise what was actually delivered (never the whole hold).
    if (usage) {
      this.quota.settle(usageId, { input: usage.inputTokens, cachedInput: usage.cachedInputTokens ?? 0, output: usage.outputTokens, reasoning: usage.reasoningTokens ?? 0 });
      this.append(taskId, 'usage', { inputTokens: usage.inputTokens, cachedInputTokens: usage.cachedInputTokens ?? 0, outputTokens: usage.outputTokens, reasoningTokens: usage.reasoningTokens ?? 0 });
    } else if (delivered === 0) this.quota.release(usageId);
    else this.quota.settle(usageId, { input: estimateTokens(JSON.stringify(request.messages)), output: Math.ceil(delivered / 1.5), estimated: true });
    this.finish(taskId, terminal);
  }

  finish(taskId, terminal) {
    const seq = this.append(taskId, terminal.type, terminal.data);
    this.db.prepare('UPDATE tasks SET state=?, finished_at=?, finish_reason=?, error_code=? WHERE id=?')
      .run(terminal.type, this.now(), terminal.data.finishReason ?? null, terminal.data.code ?? null, taskId);
    if (seq) this.onTerminal(this.db.prepare('SELECT * FROM tasks WHERE id=?').get(taskId));
  }

  cancel(accountId, id) {
    const row = this.db.prepare('SELECT * FROM tasks WHERE id=? AND account_id=?').get(id, accountId);
    if (!row) throw new GatewayError('task_not_found', 404);
    if (TERMINAL.has(row.state)) return this.snapshot(row);          // idempotent
    const run = this.running.get(id);
    if (run) run.abort.abort();
    else this.finish(id, { type: 'cancelled', data: {} });             // queued but not running (should not persist), or orphaned
    return this.snapshot(this.db.prepare('SELECT * FROM tasks WHERE id=?').get(id));
  }

  /** Resolves when the task has reached a terminal state (tests, graceful shutdown). */
  async idle(id) { await this.running.get(id)?.done; }

  // ---------- recovery and retention ----------
  /** After a restart no task is executing. Whatever was in flight ends as `failed:interrupted`; clients resubmit with a new key. */
  recover() {
    const rows = this.db.prepare("SELECT t.id, u.id AS usage_id FROM tasks t LEFT JOIN usage u ON u.task_id=t.id AND u.state='reserved' WHERE t.state IN ('queued','running')").all();
    for (const r of rows) {
      if (r.usage_id) {
        const produced = this.db.prepare("SELECT COUNT(*) AS n FROM task_events WHERE task_id=? AND type IN ('delta','reasoning','tool_call')").get(r.id).n;
        if (produced === 0) this.quota.release(r.usage_id); else this.quota.settle(r.usage_id, { input: 0, output: 0, estimated: true });
      }
      this.finish(r.id, { type: 'failed', data: { code: 'interrupted' } });
    }
    return rows.length;
  }

  /** Request bodies and event payloads hold the person's conversation: they are removed `retentionMs` after the task ended. */
  purge() {
    const cutoff = this.now() - this.retentionMs;
    const old = this.db.prepare('SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at<? AND purged_at IS NULL').all(cutoff);
    for (const t of old) {
      tx(this.db, () => {
        this.db.prepare('DELETE FROM task_events WHERE task_id=?').run(t.id);
        this.db.prepare('UPDATE tasks SET request_json=NULL, purged_at=? WHERE id=?').run(this.now(), t.id);
      });
    }
    return old.length;
  }
}
