import { randomBytes, randomInt, randomUUID, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { GatewayError, tx } from './db.mjs';

const scryptAsync = promisify(scrypt);
const SCRYPT = { N: 1 << 15, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
const SESSION_DAYS = 90;
/** A computer that stays unused for this long needs to be set up again from the phone. */
const AGENT_SESSION_DAYS = 30;
export const MAX_AGENT_SESSIONS = 8;
const DAY = 86_400_000;

export const normalizeEmail = (email) => String(email ?? '').trim().toLowerCase();
const emailOk = (email) => /^[^\s@]{1,64}@[^\s@]{1,255}$/.test(email) && email.length <= 254 && email.includes('.', email.indexOf('@'));
const sha256 = (value) => createHash('sha256').update(value).digest('hex');

export async function hashPassword(password, params = SCRYPT) {
  const salt = randomBytes(16);
  const hash = await scryptAsync(password.normalize('NFKC'), salt, params.keylen, { N: params.N, r: params.r, p: params.p, maxmem: params.maxmem });
  return `scrypt$${params.N}$${params.r}$${params.p}$${salt.toString('base64')}$${hash.toString('base64')}`;
}

export async function verifyPassword(password, stored) {
  const [scheme, N, r, p, salt, hash] = String(stored).split('$');
  if (scheme !== 'scrypt') return false;
  const expected = Buffer.from(hash, 'base64');
  const actual = await scryptAsync(password.normalize('NFKC'), Buffer.from(salt, 'base64'), expected.length, { N: +N, r: +r, p: +p, maxmem: SCRYPT.maxmem });
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export class Accounts {
  constructor(db, { now = () => Date.now(), scryptParams = SCRYPT, rate = { attempts: 8, windowMs: 15 * 60_000 }, mailer = null, appleSignIn = null } = {}) {
    this.db = db; this.now = now; this.params = scryptParams; this.rate = rate; this.mailer = mailer; this.appleSignIn = appleSignIn;
  }

  // ---- rate limiting (per bucket: "login:<email>", "login-ip:<ip>", "register-ip:<ip>") ----
  assertAllowed(bucket) {
    const since = this.now() - this.rate.windowMs;
    const { n } = this.db.prepare('SELECT COUNT(*) AS n FROM rate_events WHERE bucket=? AND at>?').get(bucket, since);
    if (n >= this.rate.attempts) throw new GatewayError('too_many_attempts', 429);
  }
  noteAttempt(bucket) {
    this.db.prepare('INSERT INTO rate_events(bucket, at) VALUES(?,?)').run(bucket, this.now());
    if (Math.random() < 0.02) this.db.prepare('DELETE FROM rate_events WHERE at<?').run(this.now() - 24 * 3_600_000);
  }

  // ---- registration, login, sessions ----
  async register({ email, password, displayName, device, ip = '' }) {
    const norm = normalizeEmail(email);
    if (!emailOk(norm)) throw new GatewayError('invalid_email');
    if (typeof password !== 'string' || password.length < 8 || password.length > 200) throw new GatewayError('weak_password');
    if (/^(.)\1+$/.test(password) || ['12345678', 'password', 'password1', '11111111'].includes(password.toLowerCase())) throw new GatewayError('weak_password');
    this.assertAllowed(`register-ip:${ip}`); this.noteAttempt(`register-ip:${ip}`);
    const name = String(displayName ?? '').trim().slice(0, 40) || norm.split('@')[0].slice(0, 40);
    const hash = await hashPassword(password, this.params);
    const id = randomUUID(), t = this.now();
    try {
      tx(this.db, () => this.db.prepare('INSERT INTO accounts(id,email,email_norm,password_hash,display_name,apple_account_token,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)')
        .run(id, String(email).trim(), norm, hash, name, randomUUID(), t, t));
    } catch (error) {
      if (/UNIQUE/.test(String(error.message))) throw new GatewayError('email_taken', 409);
      throw error;
    }
    return { account: this.profile(id), session: this.createSession(id, device) };
  }

  async login({ email, password, device, ip = '' }) {
    const norm = normalizeEmail(email);
    this.assertAllowed(`login:${norm}`); this.assertAllowed(`login-ip:${ip}`);
    const row = this.db.prepare('SELECT * FROM accounts WHERE email_norm=? AND deleted_at IS NULL').get(norm);
    // Same work and same answer whether the email exists or not.
    const ok = row ? await verifyPassword(String(password ?? ''), row.password_hash) : (await hashPassword(String(password ?? ''), this.params), false);
    if (!ok) { this.noteAttempt(`login:${norm}`); this.noteAttempt(`login-ip:${ip}`); throw new GatewayError('invalid_credentials', 401); }
    return { account: this.profile(row.id), session: this.createSession(row.id, device) };
  }

  createSession(accountId, device = {}, scope = 'full') {
    const token = randomBytes(32).toString('base64url'), t = this.now(), id = randomUUID();
    const days = scope === 'agent' ? AGENT_SESSION_DAYS : SESSION_DAYS;
    this.db.prepare('INSERT INTO sessions(id,account_id,token_hash,device_name,platform,created_at,last_used_at,expires_at,scope) VALUES(?,?,?,?,?,?,?,?,?)')
      .run(id, accountId, sha256(token), String(device?.name ?? '').slice(0, 80) || null, String(device?.platform ?? '').slice(0, 20) || null, t, t, t + days * DAY, scope);
    return { token, expiresAt: t + days * DAY, sessionId: id };
  }

  /**
   * A credential for the person's own computer. It can run model tasks under this account's subscription and quota, and nothing else (no
   * profile, no purchases, no other sessions). It appears in the session list under the computer's name and is revoked like any session.
   * Setting up the same computer again replaces its earlier credential.
   */
  createAgentSession(accountId, { name } = {}) {
    const label = `Mac · ${String(name ?? '').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 60) || '我的电脑'}`;
    tx(this.db, () => {
      this.db.prepare("UPDATE sessions SET revoked_at=? WHERE account_id=? AND scope='agent' AND device_name=? AND revoked_at IS NULL").run(this.now(), accountId, label);
      const active = this.db.prepare("SELECT id FROM sessions WHERE account_id=? AND scope='agent' AND revoked_at IS NULL AND expires_at>? ORDER BY last_used_at ASC").all(accountId, this.now());
      for (const old of active.slice(0, Math.max(0, active.length - (MAX_AGENT_SESSIONS - 1)))) this.logout(old.id);
    });
    return { ...this.createSession(accountId, { name: label, platform: 'agent' }, 'agent'), name: label };
  }

  /** Resolves a bearer token; slides the expiry when more than a day old. Returns null for unknown, expired or revoked tokens. */
  authenticate(token) {
    if (typeof token !== 'string' || token.length < 20 || token.length > 200) return null;
    const row = this.db.prepare(`SELECT s.id AS session_id, s.expires_at, s.last_used_at, s.scope, a.id AS account_id FROM sessions s JOIN accounts a ON a.id=s.account_id
      WHERE s.token_hash=? AND s.revoked_at IS NULL AND a.deleted_at IS NULL`).get(sha256(token));
    const t = this.now();
    if (!row || row.expires_at <= t) return null;
    if (t - row.last_used_at > DAY) this.db.prepare('UPDATE sessions SET last_used_at=?, expires_at=? WHERE id=?').run(t, t + (row.scope === 'agent' ? AGENT_SESSION_DAYS : SESSION_DAYS) * DAY, row.session_id);
    return { accountId: row.account_id, sessionId: row.session_id, scope: row.scope };
  }

  logout(sessionId) { this.db.prepare('UPDATE sessions SET revoked_at=? WHERE id=? AND revoked_at IS NULL').run(this.now(), sessionId); }
  logoutAll(accountId, exceptSessionId) {
    this.db.prepare('UPDATE sessions SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL AND id<>?').run(this.now(), accountId, exceptSessionId ?? '');
  }
  sessions(accountId) {
    return this.db.prepare('SELECT id, device_name AS deviceName, platform, scope, created_at AS createdAt, last_used_at AS lastUsedAt FROM sessions WHERE account_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY last_used_at DESC')
      .all(accountId, this.now());
  }

  // ---- profile ----
  profile(accountId) {
    const a = this.db.prepare('SELECT id, email, display_name, avatar_updated_at, apple_account_token, created_at, email_verified, password_hash FROM accounts WHERE id=? AND deleted_at IS NULL').get(accountId);
    if (!a) throw new GatewayError('account_not_found', 404);
    const methods = [...(a.password_hash ? ['password'] : []), ...this.db.prepare('SELECT provider FROM identities WHERE account_id=?').all(accountId).map(r => r.provider)];
    return { id: a.id, email: a.email.endsWith('@appleid.invalid') ? null : a.email, emailVerified: Boolean(a.email_verified), displayName: a.display_name, hasAvatar: Boolean(a.avatar_updated_at),
             avatarVersion: a.avatar_updated_at ?? null, appleAccountToken: a.apple_account_token, createdAt: a.created_at, signInMethods: methods };
  }
  updateProfile(accountId, { displayName }) {
    const name = String(displayName ?? '').trim();
    if (!name || name.length > 40) throw new GatewayError('invalid_name');
    this.db.prepare('UPDATE accounts SET display_name=?, updated_at=? WHERE id=?').run(name, this.now(), accountId);
    return this.profile(accountId);
  }
  setAvatar(accountId, bytes) {
    const type = imageType(bytes);
    if (!type) throw new GatewayError('unsupported_image');
    if (bytes.length > 512 * 1024) throw new GatewayError('image_too_large', 413);
    this.db.prepare('UPDATE accounts SET avatar=?, avatar_type=?, avatar_updated_at=?, updated_at=? WHERE id=?').run(bytes, type, this.now(), this.now(), accountId);
    return this.profile(accountId);
  }
  avatar(accountId) {
    const a = this.db.prepare('SELECT avatar, avatar_type FROM accounts WHERE id=? AND deleted_at IS NULL').get(accountId);
    return a?.avatar ? { bytes: Buffer.from(a.avatar), type: a.avatar_type } : null;
  }
  removeAvatar(accountId) { this.db.prepare('UPDATE accounts SET avatar=NULL, avatar_type=NULL, avatar_updated_at=NULL, updated_at=? WHERE id=?').run(this.now(), accountId); }

  async changePassword(accountId, { current, next }, keepSessionId) {
    const row = this.db.prepare('SELECT password_hash FROM accounts WHERE id=? AND deleted_at IS NULL').get(accountId);
    if (!row || !(await verifyPassword(String(current ?? ''), row.password_hash))) throw new GatewayError('invalid_credentials', 401);
    if (typeof next !== 'string' || next.length < 8 || next.length > 200) throw new GatewayError('weak_password');
    this.db.prepare('UPDATE accounts SET password_hash=?, updated_at=? WHERE id=?').run(await hashPassword(next, this.params), this.now(), accountId);
    this.logoutAll(accountId, keepSessionId);
  }

  // ---- sign in with Apple ----
  async signInWithApple({ identityToken, nonce, fullName, device }) {
    if (!this.appleSignIn) throw new GatewayError('feature_unavailable', 503);
    let claims;
    try { claims = await this.appleSignIn.verify(identityToken, { nonce }); } catch { throw new GatewayError('invalid_identity_token', 401); }
    const subject = String(claims.sub);
    const found = this.db.prepare('SELECT account_id FROM identities WHERE provider=? AND subject=?').get('apple', subject);
    if (found) {
      this.profile(found.account_id);   // throws if the account was deleted
      return { account: this.profile(found.account_id), session: this.createSession(found.account_id, device), isNewAccount: false };
    }
    const t = this.now(), id = randomUUID();
    const email = typeof claims.email === 'string' && claims.email ? claims.email : `apple-${subject}@appleid.invalid`;
    const name = [fullName?.given, fullName?.family].filter(Boolean).join(' ').trim().slice(0, 40) || (claims.email ? claims.email.split('@')[0].slice(0, 40) : 'iTalk');
    tx(this.db, () => {
      const existing = this.db.prepare('SELECT id FROM accounts WHERE email_norm=? AND deleted_at IS NULL').get(normalizeEmail(email));
      const accountId = existing && claims.email_verified ? existing.id : id;      // link only when Apple vouches for the address
      if (!existing || !claims.email_verified) {
        const unique = existing ? `apple-${subject}@appleid.invalid` : email;
        this.db.prepare('INSERT INTO accounts(id,email,email_norm,password_hash,display_name,apple_account_token,created_at,updated_at,email_verified) VALUES(?,?,?,?,?,?,?,?,?)')
          .run(id, unique, normalizeEmail(unique), '', name, randomUUID(), t, t, claims.email_verified ? 1 : 0);
      }
      this.db.prepare('INSERT INTO identities(provider,subject,account_id,created_at) VALUES(?,?,?,?)').run('apple', subject, accountId, t);
    });
    const accountId = this.db.prepare('SELECT account_id FROM identities WHERE provider=? AND subject=?').get('apple', subject).account_id;
    return { account: this.profile(accountId), session: this.createSession(accountId, device), isNewAccount: accountId === id };
  }

  // ---- one-time codes: password reset and e-mail verification ----
  issueCode(accountId, kind, ttlMs) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';           // no 0/O/1/I: typed by people
    const code = Array.from({ length: 8 }, () => alphabet[randomInt(alphabet.length)]).join('');
    this.db.prepare('UPDATE one_time_codes SET used_at=? WHERE account_id=? AND kind=? AND used_at IS NULL').run(this.now(), accountId, kind);
    this.db.prepare('INSERT INTO one_time_codes(id,account_id,kind,code_hash,expires_at,created_at) VALUES(?,?,?,?,?,?)').run(randomUUID(), accountId, kind, sha256(code), this.now() + ttlMs, this.now());
    return code;
  }
  /** Checks a code for an account. At most 5 wrong guesses per issued code. */
  redeemCode(accountId, kind, code) {
    const row = this.db.prepare('SELECT * FROM one_time_codes WHERE account_id=? AND kind=? AND used_at IS NULL ORDER BY created_at DESC LIMIT 1').get(accountId, kind);
    if (!row || row.expires_at <= this.now() || row.attempts >= 5) throw new GatewayError('invalid_token', 400);
    const ok = sha256(String(code ?? '').trim().toUpperCase()) === row.code_hash;
    if (!ok) { this.db.prepare('UPDATE one_time_codes SET attempts=attempts+1 WHERE id=?').run(row.id); throw new GatewayError('invalid_token', 400); }
    this.db.prepare('UPDATE one_time_codes SET used_at=? WHERE id=?').run(this.now(), row.id);
  }

  /** Always succeeds from the caller's point of view (no account enumeration); a code is mailed only when the account exists. */
  async requestPasswordReset({ email, ip = '' }) {
    if (!this.mailer) throw new GatewayError('feature_unavailable', 503);
    const norm = normalizeEmail(email);
    this.assertAllowed(`reset:${norm}`); this.assertAllowed(`reset-ip:${ip}`); this.noteAttempt(`reset:${norm}`); this.noteAttempt(`reset-ip:${ip}`);
    const row = this.db.prepare("SELECT id, email FROM accounts WHERE email_norm=? AND deleted_at IS NULL AND password_hash<>''").get(norm);
    if (row) await this.mailer.send({ to: row.email, template: 'password-reset', code: this.issueCode(row.id, 'reset', 30 * 60_000) });
  }
  async confirmPasswordReset({ email, code, newPassword, ip = '' }) {
    const norm = normalizeEmail(email);
    this.assertAllowed(`reset-confirm:${norm}`); this.noteAttempt(`reset-confirm:${norm}`);
    if (typeof newPassword !== 'string' || newPassword.length < 8 || newPassword.length > 200) throw new GatewayError('weak_password');
    const row = this.db.prepare('SELECT id FROM accounts WHERE email_norm=? AND deleted_at IS NULL').get(norm);
    if (!row) throw new GatewayError('invalid_token', 400);
    this.redeemCode(row.id, 'reset', code);
    this.db.prepare('UPDATE accounts SET password_hash=?, updated_at=? WHERE id=?').run(await hashPassword(newPassword, this.params), this.now(), row.id);
    this.logoutAll(row.id);
  }
  async requestEmailVerification(accountId) {
    if (!this.mailer) throw new GatewayError('feature_unavailable', 503);
    const row = this.db.prepare('SELECT email, email_verified FROM accounts WHERE id=? AND deleted_at IS NULL').get(accountId);
    if (!row || row.email.endsWith('@appleid.invalid')) throw new GatewayError('invalid_email');
    if (row.email_verified) return;
    this.assertAllowed(`verify:${accountId}`); this.noteAttempt(`verify:${accountId}`);
    await this.mailer.send({ to: row.email, template: 'verify-email', code: this.issueCode(accountId, 'verify', 24 * 3_600_000) });
  }
  confirmEmail(accountId, code) {
    this.redeemCode(accountId, 'verify', code);
    this.db.prepare('UPDATE accounts SET email_verified=1, updated_at=? WHERE id=?').run(this.now(), accountId);
  }

  /**
   * Deletes the person's data: profile fields, avatar, sessions, stored request/response content. The ledger keeps account id, amounts
   * and Apple transaction ids only (tax and refund obligations), with the email and name removed.
   */
  async deleteAccount(accountId, { password, identityToken, nonce }) {
    const row = this.db.prepare('SELECT password_hash FROM accounts WHERE id=? AND deleted_at IS NULL').get(accountId);
    if (!row) throw new GatewayError('invalid_credentials', 401);
    if (row.password_hash) {
      if (!(await verifyPassword(String(password ?? ''), row.password_hash))) throw new GatewayError('invalid_credentials', 401);
    } else {
      // Apple-only account: a fresh identity token for the same Apple subject proves it is still the owner.
      let claims;
      try { claims = await this.appleSignIn.verify(identityToken, { nonce }); } catch { throw new GatewayError('invalid_credentials', 401); }
      const mine = this.db.prepare('SELECT 1 FROM identities WHERE provider=? AND subject=? AND account_id=?').get('apple', String(claims.sub), accountId);
      if (!mine) throw new GatewayError('invalid_credentials', 401);
    }
    tx(this.db, () => {
      const t = this.now();
      this.db.prepare("UPDATE accounts SET email=?, email_norm=?, display_name='', password_hash='', avatar=NULL, avatar_type=NULL, avatar_updated_at=NULL, deleted_at=?, updated_at=? WHERE id=?")
        .run(`deleted-${accountId}@invalid`, `deleted-${accountId}@invalid`, t, t, accountId);
      this.db.prepare('UPDATE sessions SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL').run(t, accountId);
      this.db.prepare("UPDATE tasks SET request_json=NULL, purged_at=? WHERE account_id=?").run(t, accountId);
      this.db.prepare('DELETE FROM task_events WHERE task_id IN (SELECT id FROM tasks WHERE account_id=?)').run(accountId);
      this.db.prepare('DELETE FROM identities WHERE account_id=?').run(accountId);
      this.db.prepare('DELETE FROM one_time_codes WHERE account_id=?').run(accountId);
    });
  }
}

function imageType(b) {
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'image/png';
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length > 12 && b.toString('ascii', 0, 4) === 'RIFF' && b.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return null;
}
