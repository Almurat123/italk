import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

// One small wrapper so the SQL stays portable (standard SQL, no SQLite-only functions in queries): moving to Postgres later means
// replacing this file, not the services. SQLite is the single-writer development/small-deployment store.

export class GatewayError extends Error {
  constructor(code, status = 400, detail) { super(code); this.code = code; this.status = status; this.detail = detail; }
}

const MIGRATIONS = [
  // 1: accounts, sessions, rate limiting
  `CREATE TABLE accounts (
     id TEXT PRIMARY KEY, email TEXT NOT NULL, email_norm TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
     display_name TEXT NOT NULL, avatar BLOB, avatar_type TEXT, avatar_updated_at INTEGER,
     apple_account_token TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
   CREATE TABLE sessions (
     id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, token_hash TEXT NOT NULL UNIQUE,
     device_name TEXT, platform TEXT, created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, revoked_at INTEGER);
   CREATE INDEX sessions_account ON sessions(account_id);
   CREATE TABLE rate_events (bucket TEXT NOT NULL, at INTEGER NOT NULL);
   CREATE INDEX rate_events_bucket ON rate_events(bucket, at);`,
  // 2: subscriptions and Apple transactions
  `CREATE TABLE subscriptions (
     original_transaction_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), product_id TEXT NOT NULL,
     status TEXT NOT NULL, environment TEXT NOT NULL, period_start INTEGER, expires_at INTEGER, auto_renew INTEGER NOT NULL DEFAULT 1,
     latest_transaction_id TEXT, updated_at INTEGER NOT NULL);
   CREATE INDEX subscriptions_account ON subscriptions(account_id);
   CREATE TABLE apple_transactions (
     transaction_id TEXT PRIMARY KEY, original_transaction_id TEXT NOT NULL, account_id TEXT, product_id TEXT NOT NULL, type TEXT,
     purchase_date INTEGER, expires_date INTEGER, revocation_date INTEGER, environment TEXT, received_at INTEGER NOT NULL);
   CREATE TABLE apple_notifications (uuid TEXT PRIMARY KEY, type TEXT, subtype TEXT, received_at INTEGER NOT NULL);`,
  // 3: usage ledger (cost in micro-USD, 1e-6 USD) with reservations
  `CREATE TABLE usage (
     id TEXT PRIMARY KEY, account_id TEXT NOT NULL, task_id TEXT, model TEXT NOT NULL, state TEXT NOT NULL,
     reserved_micro INTEGER NOT NULL, cost_micro INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
     cached_input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, reasoning_tokens INTEGER NOT NULL DEFAULT 0,
     estimated INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, settled_at INTEGER);
   CREATE INDEX usage_account_time ON usage(account_id, created_at);
   CREATE INDEX usage_state ON usage(state);`,
  // 4: durable tasks and their ordered event log
  `CREATE TABLE tasks (
     id TEXT PRIMARY KEY, account_id TEXT NOT NULL, idem_key TEXT NOT NULL, request_digest TEXT NOT NULL, state TEXT NOT NULL,
     model TEXT NOT NULL, run_id TEXT, step INTEGER, request_json TEXT, created_at INTEGER NOT NULL, started_at INTEGER,
     finished_at INTEGER, last_seq INTEGER NOT NULL DEFAULT 0, error_code TEXT, finish_reason TEXT, purged_at INTEGER,
     UNIQUE(account_id, idem_key));
   CREATE INDEX tasks_state ON tasks(state);
   CREATE INDEX tasks_account_state ON tasks(account_id, state);
   CREATE TABLE task_events (
     task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, seq INTEGER NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL,
     created_at INTEGER NOT NULL, PRIMARY KEY(task_id, seq));`,
  // 5: sign in with Apple identities, one-time codes (password reset, e-mail verification), e-mail verified flag
  `ALTER TABLE accounts ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0;
   CREATE TABLE identities (provider TEXT NOT NULL, subject TEXT NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
     created_at INTEGER NOT NULL, PRIMARY KEY(provider, subject));
   CREATE TABLE one_time_codes (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, kind TEXT NOT NULL,
     code_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, used_at INTEGER, created_at INTEGER NOT NULL);
   CREATE INDEX one_time_codes_account ON one_time_codes(account_id, kind);`,
  // 6: scoped sessions. 'agent' sessions are issued to a paired computer: model tasks and nothing else, revocable on their own.
  `ALTER TABLE sessions ADD COLUMN scope TEXT NOT NULL DEFAULT 'full';`,
];

export function openDb(path = ':memory:') {
  if (path !== ':memory:') { mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); }
  const db = new DatabaseSync(path);
  if (path !== ':memory:') { try { chmodSync(path, 0o600); } catch {} }
  db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;');
  db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)');
  const applied = new Set(db.prepare('SELECT version FROM schema_migrations').all().map(r => r.version));
  MIGRATIONS.forEach((sql, i) => {
    const version = i + 1;
    if (applied.has(version)) return;
    db.exec('BEGIN IMMEDIATE');
    try { db.exec(sql); db.prepare('INSERT INTO schema_migrations(version, applied_at) VALUES(?,?)').run(version, Date.now()); db.exec('COMMIT'); }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  });
  return db;
}

/** Runs `fn` inside one write transaction (reservations, settlements and entitlement changes are atomic). */
export function tx(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try { const result = fn(); db.exec('COMMIT'); return result; }
  catch (error) { try { db.exec('ROLLBACK'); } catch {} throw error; }
}
