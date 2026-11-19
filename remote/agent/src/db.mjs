import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

export class AgentError extends Error {
  constructor(code, status = 400, detail) { super(code); this.code = code; this.status = status; this.detail = detail; }
}

const MIGRATIONS = [
  `CREATE TABLE phones (id TEXT PRIMARY KEY, name TEXT NOT NULL, public_key TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen INTEGER, revoked_at INTEGER);
   CREATE TABLE tasks (id TEXT PRIMARY KEY, phone_id TEXT NOT NULL, idem_key TEXT NOT NULL, request_digest TEXT NOT NULL, backend TEXT NOT NULL, model TEXT, cwd TEXT,
     permission_mode TEXT NOT NULL, title TEXT, continue_of TEXT, session_id TEXT, state TEXT NOT NULL, request_json TEXT, created_at INTEGER NOT NULL, started_at INTEGER,
     finished_at INTEGER, last_seq INTEGER NOT NULL DEFAULT 0, error_code TEXT, error_detail TEXT, usage_json TEXT, purged_at INTEGER, UNIQUE(phone_id, idem_key));
   CREATE INDEX tasks_by_phone ON tasks(phone_id, created_at DESC);
   CREATE TABLE task_events (task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, seq INTEGER NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL,
     created_at INTEGER NOT NULL, PRIMARY KEY(task_id, seq));
   CREATE TABLE approvals (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, tool TEXT NOT NULL, summary TEXT NOT NULL, risk TEXT NOT NULL,
     detail TEXT, tainted INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, scope TEXT, requested_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, resolved_at INTEGER, resolved_by TEXT);
   CREATE TABLE backend_sessions (id TEXT PRIMARY KEY, backend TEXT NOT NULL, data TEXT NOT NULL, updated_at INTEGER NOT NULL);
   CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, phone_id TEXT, task_id TEXT, tool TEXT, risk TEXT, outcome TEXT, digest TEXT);`,
  // 2: the agent's working state (transcript, plan, step counter), written after every step so a task survives a restart of this program.
  `CREATE TABLE agent_state (task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE, state_json TEXT NOT NULL, updated_at INTEGER NOT NULL);`,
  // File preimages are scoped to the initiating phone and session and removed with the task.
  `CREATE TABLE file_checkpoints (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
     phone_id TEXT NOT NULL, session_id TEXT NOT NULL, path TEXT NOT NULL, content BLOB NOT NULL, mode INTEGER NOT NULL,
     digest TEXT NOT NULL, created_at INTEGER NOT NULL);
   CREATE INDEX file_checkpoints_owner ON file_checkpoints(phone_id, session_id, created_at DESC);`,
];

export function openDb(path = ':memory:') {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(path);
  if (path !== ':memory:') { try { chmodSync(path, 0o600); } catch {} }
  db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
  db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)');
  const applied = new Set(db.prepare('SELECT version FROM schema_migrations').all().map(r => r.version));
  MIGRATIONS.forEach((sql, i) => {
    if (applied.has(i + 1)) return;
    db.exec('BEGIN IMMEDIATE');
    try { db.exec(sql); db.prepare('INSERT INTO schema_migrations(version, applied_at) VALUES(?,?)').run(i + 1, Date.now()); db.exec('COMMIT'); } catch (e) { db.exec('ROLLBACK'); throw e; }
  });
  return db;
}
export function tx(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try { const r = fn(); db.exec('COMMIT'); return r; } catch (e) { try { db.exec('ROLLBACK'); } catch {} throw e; }
}
