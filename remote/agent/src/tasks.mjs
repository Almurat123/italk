import { randomUUID, createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { AgentError, tx } from './db.mjs';
import { clampMode, MODES } from './policy.mjs';

// Durable tasks on the computer.
//
// The phone submits a task once (idempotent), then reads an ordered, persisted event log over any number of connections. The task runs
// here, on the computer, independent of the phone: locking the iPhone, leaving Wi-Fi or killing the app only ends a *reader*. A reader
// that returns asks for "events after N" and continues exactly where it stopped. A task that needs the person's approval waits (up to
// `approvalTimeoutMs`) instead of failing, and the pending approval is visible to every reconnecting reader.
//
// Event types: started{backend,model,cwd,mode} · text{text} · reasoning{text} · status{message} · tool_call{id,name,summary,risk,arguments?} ·
// tool_result{id,ok,preview} · approval_requested{approvalId,tool,summary,risk,detail,scopes,tainted,expiresAt} · approval_resolved{approvalId,outcome,scope} ·
// plan{items:[{text,status}]} · question_requested{questionId,question,choices,expiresAt} · question_answered{questionId,answered,answer?,reason?} ·
// usage{…} · terminal (exactly one): completed{} | failed{code,message} | cancelled{}.   `seq` starts at 1 with no gaps.

export const TERMINAL = new Set(['completed', 'failed', 'cancelled']);
const COALESCE_MS = 80, COALESCE_CHARS = 600;
const digestOf = (v) => createHash('sha256').update(JSON.stringify(v)).digest('hex');

export function validateTaskRequest(body, { backends, maxMode }) {
  const fail = (detail) => { throw new AgentError('invalid_arguments', 400, detail); };
  if (!body || typeof body !== 'object') fail('body');
  for (const k of Object.keys(body)) if (!['backend', 'prompt', 'history', 'model', 'cwd', 'permissionMode', 'continueTaskId', 'title', 'reasoningEffort', 'sharedMemory'].includes(k)) fail(`unknown field ${k}`);
  const backend = body.backend ?? 'italk';
  if (typeof backend !== 'string' || !backends.has(backend)) throw new AgentError('backend_not_available', 400);
  if (body.reasoningEffort !== undefined && !['none', 'low', 'high'].includes(body.reasoningEffort)) fail('reasoningEffort');
  if (typeof body.prompt !== 'string' || !body.prompt.trim() || body.prompt.length > 30_000) fail('prompt');
  const history = body.history ?? [];
  if (!Array.isArray(history) || history.length > 40 || history.some(m => !m || !['user', 'assistant'].includes(m.role) || typeof m.text !== 'string' || m.text.length > 30_000)) fail('history');
  if (body.model !== undefined && (typeof body.model !== 'string' || body.model.length > 100)) fail('model');
  if (body.cwd !== undefined && (typeof body.cwd !== 'string' || body.cwd.length > 1024)) fail('cwd');
  const requested = body.permissionMode ?? 'ask';
  if (!MODES.includes(requested)) fail('permissionMode');
  if (body.continueTaskId !== undefined && typeof body.continueTaskId !== 'string') fail('continueTaskId');
  if (body.title !== undefined && (typeof body.title !== 'string' || body.title.length > 120)) fail('title');
  const sharedMemory = body.sharedMemory ?? [];
  if (!Array.isArray(sharedMemory) || sharedMemory.length > 10 || sharedMemory.some(s => typeof s !== 'string' || !s.trim() || s.length > 500)) fail('sharedMemory');
  return { backend, reasoningEffort: body.reasoningEffort, prompt: body.prompt, history, model: body.model ?? null, cwd: body.cwd ?? null, permissionMode: clampMode(requested, maxMode),
           modeClamped: clampMode(requested, maxMode) !== requested, continueTaskId: body.continueTaskId ?? null, sharedMemory, title: (body.title ?? body.prompt).trim().replace(/\s+/g, ' ').slice(0, 80) };
}

export class Tasks extends EventEmitter {
  constructor({ db, backends, policy, maxMode = 'ask', maxConcurrent = 2, retentionMs = 30 * 86_400_000, approvalTimeoutMs = 30 * 60_000, now = () => Date.now(), log = () => {}, notify = () => {}, home }) {
    super();
    Object.assign(this, { db, backends, policy, maxMode, maxConcurrent, retentionMs, approvalTimeoutMs, now, log, notify, home });
    this.setMaxListeners(0);
    this.running = new Map();          // taskId → { abort, done }
    this.waiting = [];                 // queued task ids, FIFO
    this.pendingApprovals = new Map(); // approvalId → { resolve, taskId, timer }
    this.pendingQuestions = new Map(); // questionId → { settle, taskId, phoneId }
    this.closing = false;
    this.taskGrants = new Map();       // taskId → Set<tool>
    this.closed = false;
  }

  // ---------- submission ----------
  /** Idempotent: the same Idempotency-Key with the same request returns the existing task. */
  create(phoneId, idemKey, rawBody) {
    if (typeof idemKey !== 'string' || idemKey.length < 8 || idemKey.length > 100) throw new AgentError('idempotency_key_required', 400);
    const request = validateTaskRequest(rawBody, { backends: this.backends, maxMode: this.maxMode });
    const digest = digestOf({ ...request });
    const existing = this.db.prepare('SELECT * FROM tasks WHERE phone_id=? AND idem_key=?').get(phoneId, idemKey);
    if (existing) {
      if (existing.request_digest !== digest) throw new AgentError('idempotency_conflict', 409);
      return { task: this.snapshot(existing), created: false };
    }
    if (this.db.prepare("SELECT COUNT(*) AS n FROM tasks WHERE phone_id=? AND state IN ('queued','running')").get(phoneId).n >= 20) throw new AgentError('too_many_tasks', 429);
    let sessionId = null;
    if (request.continueTaskId) {
      const previous = this.db.prepare('SELECT * FROM tasks WHERE id=? AND phone_id=?').get(request.continueTaskId, phoneId);
      if (!previous) throw new AgentError('task_not_found', 404);
      if (previous.backend !== request.backend) throw new AgentError('invalid_arguments', 400, 'continueTaskId belongs to another backend');
      if (!previous.session_id) throw new AgentError('session_not_ready', 409, 'The earlier task has not established a session. Wait for it to start before continuing.');
      sessionId = previous.session_id;
      if (!request.cwd && previous.cwd) request.cwd = previous.cwd;      // a follow-up continues in the folder the conversation was about
    }
    if (!request.cwd) {                                                  // no folder given: the home folder, or the first allowed folder when the owner kept the home folder out
      const home = this.policy.check(this.policy.home);
      if (home.verdict !== 'root' && this.policy.roots.length) request.cwd = this.policy.roots[0];
    }
    if (request.cwd) {
      const c = this.policy.check(request.cwd);
      if (c.verdict !== 'root') throw new AgentError('cwd_not_allowed', 403, c.verdict === 'deny' ? c.reason : 'outside the folders this agent may use');
      request.cwd = c.path;
    }
    const id = randomUUID();
    tx(this.db, () => this.db.prepare(`INSERT INTO tasks(id,phone_id,idem_key,request_digest,backend,model,cwd,permission_mode,title,continue_of,session_id,state,request_json,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?, 'queued', ?,?)`).run(id, phoneId, idemKey, digest, request.backend, request.model, request.cwd, request.permissionMode, request.title, request.continueTaskId, sessionId, JSON.stringify(request), this.now()));
    this.waiting.push(id);
    queueMicrotask(() => this.pump());
    return { task: this.snapshot(this.row(id)), created: true, modeClamped: request.modeClamped };
  }

  row(id) { return this.db.prepare('SELECT * FROM tasks WHERE id=?').get(id); }
  snapshot(row) {
    const pending = this.db.prepare("SELECT COUNT(*) AS n FROM approvals WHERE task_id=? AND state='pending'").get(row.id).n;
    return { id: row.id, state: row.state, backend: row.backend, model: row.model, cwd: row.cwd, permissionMode: row.permission_mode, title: row.title, continueOf: row.continue_of,
             hasSession: Boolean(row.session_id), createdAt: row.created_at, startedAt: row.started_at, finishedAt: row.finished_at, lastSeq: row.last_seq,
             error: row.error_code ? { code: row.error_code, message: row.error_detail } : null, pendingApprovals: pending, usage: row.usage_json ? JSON.parse(row.usage_json) : null };
  }
  get(phoneId, id) {
    const row = this.db.prepare('SELECT * FROM tasks WHERE id=? AND phone_id=?').get(id, phoneId);
    if (!row) throw new AgentError('task_not_found', 404);
    return this.snapshot(row);
  }
  list(phoneId, { limit = 30 } = {}) { return this.db.prepare('SELECT * FROM tasks WHERE phone_id=? ORDER BY created_at DESC LIMIT ?').all(phoneId, Math.min(limit, 100)).map(r => this.snapshot(r)); }
  listAll({ limit = 50 } = {}) { return this.db.prepare('SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?').all(limit).map(r => this.snapshot(r)); }

  // ---------- event log ----------
  events(phoneId, id, after = 0, limit = 500) {
    if (!this.db.prepare('SELECT 1 FROM tasks WHERE id=? AND phone_id=?').get(id, phoneId)) throw new AgentError('task_not_found', 404);
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
  subscribe(taskId, listener) { this.on(`task:${taskId}`, listener); return () => this.off(`task:${taskId}`, listener); }

  // ---------- scheduling and execution ----------
  pump() {
    while (!this.closed && this.running.size < this.maxConcurrent && this.waiting.length) {
      // CONTEXT MEMORY
      // Updated: 2026-11-02
      // Status: verified
      // Why: Follow-ups share one persisted conversation and must not overwrite each other's context.
      // Debug Goal: Serialize a conversation without blocking independent conversations.
      // Search Tags: remote session concurrent follow-up queue lost history
      // Invariants:
      // - At most one running task may use a given session id.
      // - A waiting task in another session may use an available worker.
      // Failure Modes:
      // - Concurrent session saves discard a completed follow-up.
      const activeSessions = new Set([...this.running.keys()].map(id => this.row(id)?.session_id).filter(Boolean));
      const next = this.waiting.findIndex(id => {
        const candidate = this.row(id);
        return !candidate || candidate.state !== 'queued' || !candidate.session_id || !activeSessions.has(candidate.session_id);
      });
      if (next < 0) break;
      const [id] = this.waiting.splice(next, 1), row = this.row(id);
      if (!row || row.state !== 'queued') continue;
      const abort = new AbortController();
      const done = this.execute(row, abort).catch(error => this.log('task_error', { taskId: id, code: error?.code ?? 'internal' })).finally(() => { this.running.delete(id); this.taskGrants.delete(id); this.emit('busy', this.running.size); this.pump(); });
      this.running.set(id, { abort, done });
      this.emit('busy', this.running.size);
    }
  }

  async execute(row, abort) {
    const backend = this.backends.get(row.backend);
    const request = JSON.parse(row.request_json);
    const resumed = Boolean(row.started_at), saved = resumed ? this.loadState(row.id) : null;
    this.db.prepare("UPDATE tasks SET state='running', started_at=COALESCE(started_at, ?) WHERE id=? AND state='queued'").run(this.now(), row.id);
    if (!resumed) this.append(row.id, 'started', { backend: row.backend, model: row.model, cwd: row.cwd, mode: row.permission_mode });
    let buffer = { type: null, text: '' }, timer = null;
    const flush = () => { clearTimeout(timer); timer = null; if (buffer.text) this.append(row.id, buffer.type, { text: buffer.text }); buffer = { type: null, text: '' }; };
    const buffered = (type, text) => {
      if (!text) return;
      if (buffer.type && buffer.type !== type) flush();
      buffer.type = type; buffer.text += text;
      if (buffer.text.length >= COALESCE_CHARS) flush(); else if (!timer) timer = setTimeout(flush, COALESCE_MS);
    };
    const ctx = {
      task: { id: row.id, phoneId: row.phone_id, prompt: request.prompt, history: request.history, model: row.model, cwd: row.cwd, mode: row.permission_mode, sessionId: row.session_id, reasoningEffort: request.reasoningEffort, sharedMemory: request.sharedMemory ?? [] },
      resume: saved ? { state: saved, sessionId: row.session_id } : null,
      signal: abort.signal, policy: this.policy, home: this.home,
      text: (t) => buffered('text', t), reasoning: (t) => buffered('reasoning', t),
      status: (message) => { flush(); this.append(row.id, 'status', { message: String(message).slice(0, 300) }); },
      toolCall: (call) => { flush(); this.append(row.id, 'tool_call', call); },
      toolResult: (result) => { flush(); this.append(row.id, 'tool_result', result); },
      usage: (usage) => { flush(); this.append(row.id, 'usage', usage); this.recordUsage(row.id, usage); },
      setSession: (sessionId) => this.db.prepare('UPDATE tasks SET session_id=? WHERE id=?').run(String(sessionId), row.id),
      setModel: (model) => this.db.prepare('UPDATE tasks SET model=? WHERE id=?').run(String(model), row.id),
      approve: (req) => { flush(); return this.requestApproval(row, req, abort.signal); },
      plan: (items) => { flush(); this.append(row.id, 'plan', { items }); },
      ask: (q) => { flush(); return this.askQuestion(row, q, abort.signal); },
      checkpoint: (state) => this.saveState(row.id, state),
      audit: (entry) => this.audit(row, entry),
    };
    let terminal;
    try {
      await backend.run(ctx);
      if (this.closing) { flush(); return; }                                    // this program is stopping: the task continues after the restart
      flush();
      terminal = abort.signal.aborted ? { type: 'cancelled', data: {} } : { type: 'completed', data: {} };
    } catch (error) {
      flush();
      if (this.closing) return;
      if (abort.signal.aborted) terminal = { type: 'cancelled', data: {} };
      else terminal = { type: 'failed', data: { code: error?.code && typeof error.code === 'string' ? error.code : 'backend_error', message: String(error?.message ?? error).slice(0, 300) } };
    }
    this.cancelApprovals(row.id, 'cancelled');
    this.finish(row.id, terminal);
  }

  recordUsage(taskId, usage) {
    const row = this.row(taskId), prev = row?.usage_json ? JSON.parse(row.usage_json) : {};
    const sum = { ...prev };
    for (const [k, v] of Object.entries(usage)) if (typeof v === 'number') sum[k] = (sum[k] ?? 0) + v;
    this.db.prepare('UPDATE tasks SET usage_json=? WHERE id=?').run(JSON.stringify(sum), taskId);
  }

  finish(taskId, terminal) {
    // CONTEXT MEMORY
    // Updated: 2026-11-02
    // Status: verified
    // Why: A crash between the terminal event and task state creates contradictory durable history.
    // Debug Goal: Restart and streaming readers observe one committed outcome.
    // Search Tags: task terminal event atomic restart duplicate finish
    // Invariants:
    // - Commit the terminal event and terminal state together before notifying readers.
    // - A finished task cannot append another terminal event.
    // Failure Modes:
    // - Restart resumes an already completed task or emits two terminal events.
    const data = terminal.data ?? {};
    const seq = tx(this.db, () => {
      const row = this.row(taskId);
      if (!row || TERMINAL.has(row.state)) return null;
      const next = row.last_seq + 1;
      this.db.prepare('INSERT INTO task_events(task_id,seq,type,payload,created_at) VALUES(?,?,?,?,?)').run(taskId, next, terminal.type, JSON.stringify(data), this.now());
      this.db.prepare('UPDATE tasks SET state=?, finished_at=?, error_code=?, error_detail=?, last_seq=? WHERE id=?').run(terminal.type, this.now(), data.code ?? null, data.message ?? null, next, taskId);
      return next;
    });
    if (seq) {
      this.emit(`task:${taskId}`, { seq, type: terminal.type, data });
      this.notify(this.snapshot(this.row(taskId)));
    }
  }

  cancel(phoneId, id) {
    const row = this.db.prepare('SELECT * FROM tasks WHERE id=? AND phone_id=?').get(id, phoneId);
    if (!row) throw new AgentError('task_not_found', 404);
    return this.cancelRow(row);
  }
  cancelRow(row) {
    if (TERMINAL.has(row.state)) return this.snapshot(row);
    const run = this.running.get(row.id);
    if (run) run.abort.abort();
    else { this.waiting = this.waiting.filter(x => x !== row.id); this.cancelApprovals(row.id, 'cancelled'); this.finish(row.id, { type: 'cancelled', data: {} }); }
    return this.snapshot(this.row(row.id));
  }
  async idle(id) { await this.running.get(id)?.done; }
  async drain() { await Promise.all([...this.running.values()].map(r => r.done)); }
  /** Stops scheduling (queued tasks stay queued and end as interrupted after the restart) and aborts what is running. */
  shutdown() { this.closed = true; this.closing = true; this.waiting = []; for (const r of this.running.values()) r.abort.abort(Object.assign(new Error('shutdown'), { code: 'shutdown' })); for (const q of [...this.pendingQuestions.values()]) q.settle(false, '', 'cancelled'); }

  /** Removes a finished task and everything stored about it. */
  delete(phoneId, id) {
    const row = this.db.prepare('SELECT * FROM tasks WHERE id=? AND phone_id=?').get(id, phoneId);
    if (!row) throw new AgentError('task_not_found', 404);
    if (!TERMINAL.has(row.state)) throw new AgentError('task_running', 409);
    this.db.prepare('DELETE FROM tasks WHERE id=?').run(id);
  }

  // ---------- agent state (survives a restart) ----------
  saveState(taskId, state) {
    this.db.prepare('INSERT INTO agent_state(task_id,state_json,updated_at) VALUES(?,?,?) ON CONFLICT(task_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at').run(taskId, JSON.stringify(state), this.now());
  }
  loadState(taskId) {
    const row = this.db.prepare('SELECT state_json FROM agent_state WHERE task_id=?').get(taskId);
    if (!row) return null;
    try { return JSON.parse(row.state_json); } catch { return null; }
  }

  // ---------- questions the agent asks the person ----------
  askQuestion(row, { question, choices = [] }, signal) {
    const taskId = row.id, id = randomUUID(), expiresAt = this.now() + this.approvalTimeoutMs;
    this.append(taskId, 'question_requested', { questionId: id, question, choices, expiresAt });
    this.notify({ kind: 'question', taskId, questionId: id, summary: question });
    return new Promise((resolve) => {
      const settle = (answered, text, reason) => {
        const entry = this.pendingQuestions.get(id);
        if (!entry) return false;
        clearTimeout(entry.timer); this.pendingQuestions.delete(id);
        this.append(taskId, 'question_answered', { questionId: id, answered, ...(answered ? { answer: text } : { reason }) });
        resolve({ answered, text, reason });
        return true;
      };
      const timer = setTimeout(() => settle(false, '', 'expired'), this.approvalTimeoutMs);
      this.pendingQuestions.set(id, { settle, taskId, phoneId: row.phone_id, timer });
      signal?.addEventListener('abort', () => settle(false, '', 'cancelled'), { once: true });
    });
  }
  answerQuestion(phoneId, questionId, text) {
    const entry = this.pendingQuestions.get(questionId);
    if (!entry || entry.phoneId !== phoneId) throw new AgentError('question_not_found', 404);
    if (typeof text !== 'string' || !text.trim() || text.length > 4000) throw new AgentError('invalid_arguments', 400, 'answer');
    entry.settle(true, text.trim(), null);
    return { ok: true };
  }

  // ---------- approvals ----------
  requestApproval(row, { tool, summary, risk = 'modify', detail = {}, tainted = false, scopes }, signal) {
    const taskId = row.id;
    const key = `${tool}:${risk}`;                     // a task-wide approval never stretches to a more dangerous kind of use of the same tool
    if (this.taskGrants.get(taskId)?.has(key) && risk !== 'sensitive' && !tainted) {
      this.audit(row, { tool, risk, outcome: 'task_grant', digest: digestOf(detail).slice(0, 12) });
      return Promise.resolve({ approved: true, scope: 'task', basis: 'task_grant' });
    }
    const id = randomUUID(), at = this.now(), expiresAt = at + this.approvalTimeoutMs;
    const offered = scopes ?? (risk === 'sensitive' || risk === 'external' || tainted ? ['once'] : ['once', 'task']);
    this.db.prepare("INSERT INTO approvals(id,task_id,tool,summary,risk,detail,tainted,state,requested_at,expires_at) VALUES(?,?,?,?,?,?,?, 'pending', ?,?)")
      .run(id, taskId, tool, summary.slice(0, 400), risk, JSON.stringify(detail), tainted ? 1 : 0, at, expiresAt);
    this.append(taskId, 'approval_requested', { approvalId: id, tool, summary: summary.slice(0, 400), risk, detail, scopes: offered, tainted, expiresAt });
    this.notify({ kind: 'approval', taskId, approvalId: id, summary });
    return new Promise((resolve) => {
      const settle = (outcome, scope, by) => {
        const entry = this.pendingApprovals.get(id);
        if (!entry) return false;
        clearTimeout(entry.timer); this.pendingApprovals.delete(id);
        this.db.prepare('UPDATE approvals SET state=?, scope=?, resolved_at=?, resolved_by=? WHERE id=?').run(outcome, scope ?? null, this.now(), by ?? null, id);
        this.append(taskId, 'approval_resolved', { approvalId: id, outcome, scope: scope ?? null });
        if (outcome === 'approved' && scope === 'task') { if (!this.taskGrants.has(taskId)) this.taskGrants.set(taskId, new Set()); this.taskGrants.get(taskId).add(key); }
        this.audit(row, { tool, risk, outcome: outcome === 'approved' ? 'user_approved' : outcome === 'declined' ? 'user_declined' : outcome, digest: digestOf(detail).slice(0, 12) });
        resolve({ approved: outcome === 'approved', scope: scope ?? null, outcome });
        return true;
      };
      const timer = setTimeout(() => settle('expired', null, 'timeout'), this.approvalTimeoutMs);
      this.pendingApprovals.set(id, { settle, taskId, offered, timer });
      signal?.addEventListener('abort', () => settle('cancelled', null, 'task'), { once: true });
    });
  }

  /** `by` is the paired phone's id or "mac" when answered in the terminal. */
  resolveApproval(approvalId, { decision, scope = 'once', by }, { phoneId } = {}) {
    const row = this.db.prepare('SELECT a.*, t.phone_id FROM approvals a JOIN tasks t ON t.id=a.task_id WHERE a.id=?').get(approvalId);
    if (!row || (phoneId && row.phone_id !== phoneId)) throw new AgentError('approval_not_found', 404);
    if (row.state !== 'pending') return { approval: this.approvalView(this.db.prepare('SELECT * FROM approvals WHERE id=?').get(approvalId)), alreadyResolved: true };
    const entry = this.pendingApprovals.get(approvalId);
    if (!entry) { this.db.prepare("UPDATE approvals SET state='expired', resolved_at=? WHERE id=?").run(this.now(), approvalId); throw new AgentError('approval_expired', 410); }
    if (!['approve', 'decline'].includes(decision)) throw new AgentError('invalid_arguments', 400, 'decision');
    const chosen = decision === 'approve' ? (entry.offered.includes(scope) ? scope : 'once') : null;
    entry.settle(decision === 'approve' ? 'approved' : 'declined', chosen, by);
    return { approval: this.approvalView(this.db.prepare('SELECT * FROM approvals WHERE id=?').get(approvalId)) };
  }
  approvalView(a) { return { id: a.id, taskId: a.task_id, tool: a.tool, summary: a.summary, risk: a.risk, detail: a.detail ? JSON.parse(a.detail) : {}, tainted: Boolean(a.tainted), state: a.state, scope: a.scope, requestedAt: a.requested_at, expiresAt: a.expires_at, resolvedAt: a.resolved_at }; }
  pending(phoneId) {
    const rows = phoneId ? this.db.prepare("SELECT a.* FROM approvals a JOIN tasks t ON t.id=a.task_id WHERE a.state='pending' AND t.phone_id=? ORDER BY a.requested_at").all(phoneId)
                         : this.db.prepare("SELECT * FROM approvals WHERE state='pending' ORDER BY requested_at").all();
    return rows.map(a => this.approvalView(a));
  }
  cancelApprovals(taskId, outcome) { for (const [id, e] of [...this.pendingApprovals]) if (e.taskId === taskId) e.settle(outcome, null, 'task'); }

  audit(row, { tool, risk, outcome, digest }) { this.db.prepare('INSERT INTO audit(at,phone_id,task_id,tool,risk,outcome,digest) VALUES(?,?,?,?,?,?,?)').run(this.now(), row.phone_id, row.id, tool, risk, outcome, digest ?? null); }
  recentAudit(phoneId, limit = 100) { return this.db.prepare('SELECT at, task_id AS taskId, tool, risk, outcome, digest FROM audit WHERE (? IS NULL OR phone_id=?) ORDER BY id DESC LIMIT ?').all(phoneId ?? null, phoneId ?? null, Math.min(limit, 500)); }

  // ---------- recovery and retention ----------
  /** After a restart nothing is executing. Whatever was in flight ends as `failed:interrupted`; the phone may continue it as a new task. */
  recover({ resumeWindowMs = 12 * 3_600_000 } = {}) {
    this.db.prepare("UPDATE approvals SET state='expired', resolved_at=? WHERE state='pending'").run(this.now());
    const rows = this.db.prepare("SELECT id, backend, state, created_at FROM tasks WHERE state IN ('queued','running')").all();
    let resumed = 0, failed = 0;
    for (const r of rows) {
      const saved = this.backends.get(r.backend)?.resumable && this.db.prepare('SELECT 1 FROM agent_state WHERE task_id=?').get(r.id);
      if ((saved || r.state === 'queued') && this.now() - r.created_at < resumeWindowMs) {
        if (r.state === 'running') { this.db.prepare("UPDATE tasks SET state='queued' WHERE id=?").run(r.id); this.append(r.id, 'status', { message: 'The computer restarted; this task continues from its last saved step.' }); }
        this.waiting.push(r.id); resumed += 1;
      } else { this.finish(r.id, { type: 'failed', data: { code: 'interrupted', message: 'The agent restarted while this task was running.' } }); failed += 1; }
    }
    if (resumed) queueMicrotask(() => this.pump());
    return failed;
  }
  purge() {
    const cutoff = this.now() - this.retentionMs;
    const old = this.db.prepare('SELECT id FROM tasks WHERE finished_at IS NOT NULL AND finished_at<? AND purged_at IS NULL').all(cutoff);
    for (const t of old) tx(this.db, () => {
      this.db.prepare('DELETE FROM task_events WHERE task_id=?').run(t.id);
      this.db.prepare('DELETE FROM agent_state WHERE task_id=?').run(t.id);
      this.db.prepare('DELETE FROM file_checkpoints WHERE task_id=?').run(t.id);
      this.db.prepare('UPDATE tasks SET request_json=NULL, purged_at=? WHERE id=?').run(this.now(), t.id);
    });
    return old.length;
  }
}
