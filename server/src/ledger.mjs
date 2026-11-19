import { DatabaseSync } from 'node:sqlite';
import { randomUUID, createHash } from 'node:crypto';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

export class GatewayError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}

export class Ledger {
  constructor(path = ':memory:') {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    if (path !== ':memory:') chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, account_token TEXT UNIQUE NOT NULL, balance INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS turns (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), digest TEXT NOT NULL,
        status TEXT NOT NULL, reserved INTEGER NOT NULL, charged INTEGER NOT NULL DEFAULT 0,
        input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, model TEXT NOT NULL,
        rates TEXT NOT NULL, created_at INTEGER NOT NULL, finished_at INTEGER);
      CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
        kind TEXT NOT NULL, amount INTEGER NOT NULL, reference TEXT UNIQUE NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS purchases (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
        product TEXT NOT NULL, credits INTEGER NOT NULL, refunded INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS revocations (id TEXT PRIMARY KEY);`);
    const columns = new Set(this.db.prepare('PRAGMA table_info(turns)').all().map(row => row.name));
    if (!columns.has('kind')) this.db.exec("ALTER TABLE turns ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'");
    if (!columns.has('characters')) this.db.exec('ALTER TABLE turns ADD COLUMN characters INTEGER NOT NULL DEFAULT 0');
    if (!columns.has('dispatched')) this.db.exec('ALTER TABLE turns ADD COLUMN dispatched INTEGER NOT NULL DEFAULT 0');
  }
  close() { this.db.close(); }
  atomic(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = fn(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  account(id) {
    this.db.prepare('INSERT OR IGNORE INTO accounts(id,account_token) VALUES(?,?)').run(id, randomUUID());
    const row = this.db.prepare('SELECT * FROM accounts WHERE id=?').get(id);
    const held = this.db.prepare("SELECT COALESCE(SUM(reserved),0) AS amount FROM turns WHERE account_id=? AND status IN ('pending','uncertain')").get(id).amount;
    return { id: row.id, appAccountToken: row.account_token, balance: row.balance, available: row.balance - held };
  }
  topUp(id, amount, reference) {
    if (!Number.isSafeInteger(amount) || amount <= 0) throw new GatewayError('invalid_credit');
    return this.atomic(() => {
      this.account(id);
      const existing = this.db.prepare('SELECT * FROM entries WHERE reference=?').get(reference);
      if (existing) {
        if (existing.account_id !== id || existing.amount !== amount) throw new GatewayError('credit_conflict', 409);
        return this.account(id);
      }
      const balance = this.account(id).balance;
      if (!Number.isSafeInteger(balance + amount)) throw new GatewayError('balance_overflow');
      this.db.prepare('UPDATE accounts SET balance=balance+? WHERE id=?').run(amount, id);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), id, 'credit', amount, reference, Date.now());
      return this.account(id);
    });
  }

  // CONTEXT MEMORY
  // Updated: 2026-10-28
  // Status: verified
  // Why: Concurrent requests and retries must not overspend or charge twice.
  // Debug Goal: Reserve before provider dispatch and settle real usage exactly once locally.
  // Search Tags: api relay billing reservation duplicate turn token settlement
  // Invariants:
  // - A turn ID belongs to one account and immutable request digest.
  // - Customer balances use integer microcredits and server-owned prices.
  // Failure Modes:
  // - Client retries cause a second provider call and double debit.
  // - A dispatched request with unknown usage keeps its hold until reconciliation.
  // - A process crash leaves spendable credits without reconciling dispatched work.
  reserve({ id, accountId, digest, maximum, model, rates, kind = 'text' }) {
    if (!['text', 'voice'].includes(kind)) throw new GatewayError('invalid_usage_kind');
    if (!Number.isSafeInteger(maximum) || maximum <= 0) throw new GatewayError('invalid_reservation');
    return this.atomic(() => {
      const existing = this.db.prepare('SELECT * FROM turns WHERE id=?').get(id);
      if (existing) {
        if (existing.account_id !== accountId || existing.digest !== digest) throw new GatewayError('turn_conflict', 409);
        throw new GatewayError(existing.status === 'pending' ? 'turn_in_progress' : 'turn_already_processed', 409);
      }
      if (this.account(accountId).available < maximum) throw new GatewayError('insufficient_credits', 402);
      const pending = this.db.prepare("SELECT COUNT(*) AS count FROM turns WHERE account_id=? AND status IN ('pending','uncertain')").get(accountId).count;
      if (pending >= 1) throw new GatewayError('turn_in_progress', 409);
      this.db.prepare('INSERT INTO turns(id,account_id,digest,status,reserved,model,rates,created_at,kind) VALUES(?,?,?,?,?,?,?,?,?)')
        .run(id, accountId, digest, 'pending', maximum, model, JSON.stringify(rates), Date.now(), kind);
    });
  }
  settle(id, { inputTokens, outputTokens, searches = 0 }) {
    if (![inputTokens, outputTokens, searches].every(n => Number.isSafeInteger(n) && n >= 0)) throw new GatewayError('invalid_usage', 502);
    return this.atomic(() => {
      const turn = this.db.prepare('SELECT * FROM turns WHERE id=?').get(id);
      if (!turn) throw new GatewayError('unknown_turn');
      if (!['pending', 'uncertain'].includes(turn.status)) return turn.charged;
      const rates = JSON.parse(turn.rates);
      const calculated = Math.ceil((inputTokens * rates.input + outputTokens * rates.output) / 1_000_000) + searches * rates.search;
      if (!Number.isSafeInteger(calculated)) throw new GatewayError('invalid_usage', 502);
      // The operator absorbs usage above the disclosed reservation, never overdrawing a customer.
      const charged = Math.min(calculated, turn.reserved);
      this.db.prepare('UPDATE accounts SET balance=balance-? WHERE id=?').run(charged, turn.account_id);
      this.db.prepare("UPDATE turns SET status='completed',charged=?,input_tokens=?,output_tokens=?,finished_at=? WHERE id=?")
        .run(charged, inputTokens, outputTokens, Date.now(), id);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), turn.account_id, 'usage', -charged, `turn:${id}`, Date.now());
      return charged;
    });
  }
  markDispatched(id) {
    const result = this.db.prepare("UPDATE turns SET dispatched=1 WHERE id=? AND status='pending'").run(id);
    if (result.changes !== 1) throw new GatewayError('unknown_turn');
  }
  fail(id) {
    this.db.prepare("UPDATE turns SET status=CASE WHEN dispatched=1 THEN 'uncertain' ELSE 'failed' END, reserved=CASE WHEN dispatched=1 THEN reserved ELSE 0 END, finished_at=? WHERE id=? AND status='pending'").run(Date.now(), id);
  }
  // Operator-only primitive; deliberately not exposed through the customer HTTP API.
  voidUncertain(id, reason) {
    if (typeof reason !== 'string' || reason.trim().length < 8 || reason.length > 500) throw new GatewayError('invalid_reconciliation_reason');
    return this.atomic(() => {
      const turn = this.db.prepare('SELECT * FROM turns WHERE id=?').get(id);
      if (!turn || turn.status !== 'uncertain') throw new GatewayError('turn_not_uncertain', 409);
      this.db.prepare("UPDATE turns SET status='reconciled_void',reserved=0,finished_at=? WHERE id=?").run(Date.now(), id);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), turn.account_id, 'reconciliation', 0, `reconcile:${id}:${reason.trim()}`, Date.now());
      return this.account(turn.account_id);
    });
  }
  settleVoice(id, characters) {
    if (!Number.isSafeInteger(characters) || characters <= 0 || characters > 100_000) throw new GatewayError('invalid_usage', 502);
    return this.atomic(() => {
      const turn = this.db.prepare('SELECT * FROM turns WHERE id=?').get(id);
      if (!turn || turn.kind !== 'voice') throw new GatewayError('invalid_usage_kind');
      if (!['pending', 'uncertain'].includes(turn.status)) return turn.charged;
      const rate = JSON.parse(turn.rates).characters;
      if (!Number.isSafeInteger(rate) || rate < 0) throw new GatewayError('invalid_usage', 502);
      const calculated = Math.ceil(characters * rate / 1_000_000);
      if (!Number.isSafeInteger(calculated)) throw new GatewayError('invalid_usage', 502);
      const charged = Math.min(calculated, turn.reserved);
      this.db.prepare('UPDATE accounts SET balance=balance-? WHERE id=?').run(charged, turn.account_id);
      this.db.prepare("UPDATE turns SET status='completed',charged=?,characters=?,finished_at=? WHERE id=?")
        .run(charged, characters, Date.now(), id);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), turn.account_id, 'usage', -charged, `turn:${id}`, Date.now());
      return charged;
    });
  }
  recoverInterrupted() {
    // Preserve dispatched holds until an operator can establish the provider's actual outcome.
    this.db.prepare("UPDATE turns SET status=CASE WHEN dispatched=1 THEN 'uncertain' ELSE 'interrupted' END, reserved=CASE WHEN dispatched=1 THEN reserved ELSE 0 END, finished_at=? WHERE status='pending'").run(Date.now());
  }
  usage(accountId) {
    return this.db.prepare('SELECT id,status,charged,reserved,input_tokens AS inputTokens,output_tokens AS outputTokens,kind,characters,model,created_at AS createdAt FROM turns WHERE account_id=? ORDER BY created_at DESC LIMIT 100').all(accountId);
  }
  purchase(accountId, transaction, credits) {
    return this.atomic(() => {
      const account = this.account(accountId);
      if (transaction.appAccountToken?.toLowerCase() !== account.appAccountToken.toLowerCase()) throw new GatewayError('purchase_account_mismatch', 403);
      if (this.db.prepare('SELECT id FROM revocations WHERE id=?').get(transaction.transactionId)) throw new GatewayError('purchase_revoked', 403);
      const existing = this.db.prepare('SELECT * FROM purchases WHERE id=?').get(transaction.transactionId);
      if (existing) {
        if (existing.account_id !== accountId) throw new GatewayError('purchase_account_mismatch', 403);
        return account;
      }
      if (transaction.revocationDate) throw new GatewayError('purchase_revoked', 403);
      if (!Number.isSafeInteger(credits) || credits <= 0 || !Number.isSafeInteger(account.balance + credits)) throw new GatewayError('invalid_credit');
      this.db.prepare('INSERT INTO purchases VALUES(?,?,?,?,0)').run(transaction.transactionId, accountId, transaction.productId, credits);
      this.db.prepare('UPDATE accounts SET balance=balance+? WHERE id=?').run(credits, accountId);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), accountId, 'purchase', credits, `purchase:${transaction.transactionId}`, Date.now());
      return this.account(accountId);
    });
  }
  refund(transaction) {
    return this.atomic(() => {
      this.db.prepare('INSERT OR IGNORE INTO revocations VALUES(?)').run(transaction.transactionId);
      const purchase = this.db.prepare('SELECT * FROM purchases WHERE id=?').get(transaction.transactionId);
      if (!purchase || purchase.refunded) return;
      this.db.prepare('UPDATE accounts SET balance=balance-? WHERE id=?').run(purchase.credits, purchase.account_id);
      this.db.prepare('UPDATE purchases SET refunded=1 WHERE id=?').run(purchase.id);
      this.db.prepare('INSERT INTO entries VALUES(?,?,?,?,?,?)').run(randomUUID(), purchase.account_id, 'refund', -purchase.credits, `refund:${purchase.id}`, Date.now());
    });
  }
}

export const requestDigest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
