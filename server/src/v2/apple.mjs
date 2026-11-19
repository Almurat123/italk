import { createPublicKey, createVerify, createHash, X509Certificate } from 'node:crypto';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { GatewayError, tx } from './db.mjs';

// ---------- Sign in with Apple: identity-token verification (RS256 against Apple's published keys) ----------
export class AppleSignIn {
  constructor({ bundleId, fetchKeys, now = () => Date.now() }) { Object.assign(this, { bundleId, fetchKeys, now }); this.cache = { at: 0, keys: [] }; }
  async keys() {
    if (this.now() - this.cache.at > 3_600_000 || !this.cache.keys.length) this.cache = { at: this.now(), keys: await this.fetchKeys() };
    return this.cache.keys;
  }
  async verify(token, { nonce } = {}) {
    const [h, p, sig] = String(token).split('.');
    if (!h || !p || !sig) throw new Error('malformed');
    const header = JSON.parse(Buffer.from(h, 'base64url').toString()), claims = JSON.parse(Buffer.from(p, 'base64url').toString());
    if (header.alg !== 'RS256') throw new Error('alg');
    const jwk = (await this.keys()).find(k => k.kid === header.kid);
    if (!jwk) throw new Error('kid');
    const ok = createVerify('RSA-SHA256').update(`${h}.${p}`).verify(createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(sig, 'base64url'));
    if (!ok) throw new Error('signature');
    const t = this.now() / 1000;
    if (claims.iss !== 'https://appleid.apple.com' || claims.aud !== this.bundleId || !(claims.exp > t) || !(claims.iat <= t + 300) || !claims.sub) throw new Error('claims');
    if (nonce !== undefined) {
      const hashed = createHash('sha256').update(String(nonce)).digest('hex');
      if (claims.nonce !== nonce && claims.nonce !== hashed) throw new Error('nonce');
    } else if (claims.nonce) throw new Error('nonce_required');
    return claims;
  }
}

// ---------- App Store: transactions and server notifications ----------
const AUTO_RENEWABLE = 'Auto-Renewable Subscription';

/** Loads Apple's root certificates (DER) from a directory of .cer/.der files (AppleRootCA-G3 etc. downloaded from apple.com/certificateauthority). */
export function loadAppleRoots(dir) {
  if (!dir || !existsSync(dir)) return [];
  return readdirSync(dir).filter(f => /\.(cer|der)$/i.test(f)).map(f => readFileSync(join(dir, f)));
}

export class Purchases {
  /** `verifier` is an @apple/app-store-server-library SignedDataVerifier (or any object with verifyAndDecodeTransaction/Notification/RenewalInfo). */
  constructor({ db, pricing, verifier, now = () => Date.now() }) { Object.assign(this, { db, pricing, verifier, now }); }

  get available() { return Boolean(this.verifier); }

  /** Attaches verified transactions to the account that made them (purchase and Restore Purchases). */
  async attach(accountId, appleAccountToken, signedTransactions) {
    if (!this.verifier) throw new GatewayError('feature_unavailable', 503);
    if (!Array.isArray(signedTransactions) || !signedTransactions.length || signedTransactions.length > 20) throw new GatewayError('invalid_arguments');
    let attached = 0;
    for (const jws of signedTransactions) {
      let tr;
      try { tr = await this.verifier.verifyAndDecodeTransaction(jws); } catch { throw new GatewayError('invalid_transaction', 400); }
      if (tr.type !== AUTO_RENEWABLE || !this.pricing.plan(tr.productId)) continue;               // other products are not ours to grant
      if (!tr.appAccountToken || tr.appAccountToken.toLowerCase() !== appleAccountToken.toLowerCase()) throw new GatewayError('transaction_belongs_to_another_account', 403);
      this.record(accountId, tr);
      attached++;
    }
    return attached;
  }

  record(accountId, tr, patch = {}) {
    const t = this.now();
    const expires = tr.expiresDate ?? null, revoked = tr.revocationDate ?? null;
    tx(this.db, () => {
      this.db.prepare('INSERT OR IGNORE INTO apple_transactions(transaction_id,original_transaction_id,account_id,product_id,type,purchase_date,expires_date,revocation_date,environment,received_at) VALUES(?,?,?,?,?,?,?,?,?,?)')
        .run(String(tr.transactionId), String(tr.originalTransactionId), accountId, tr.productId, tr.type, tr.purchaseDate ?? null, expires, revoked, tr.environment ?? null, t);
      const existing = this.db.prepare('SELECT * FROM subscriptions WHERE original_transaction_id=?').get(String(tr.originalTransactionId));
      // Only a newer transaction may move the period forward; an old one arriving late never shortens the entitlement.
      if (existing && existing.expires_at && expires && expires < existing.expires_at && !revoked && !patch.status) return;
      const status = patch.status ?? (revoked ? 'revoked' : expires && expires > t ? 'active' : 'expired');
      this.db.prepare(`INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,latest_transaction_id,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(original_transaction_id) DO UPDATE SET product_id=excluded.product_id, status=excluded.status, period_start=excluded.period_start,
          expires_at=excluded.expires_at, auto_renew=excluded.auto_renew, latest_transaction_id=excluded.latest_transaction_id, updated_at=excluded.updated_at`)
        .run(String(tr.originalTransactionId), accountId, tr.productId, status, tr.environment ?? 'Production', tr.purchaseDate ?? null, expires,
             patch.autoRenew ?? existing?.auto_renew ?? 1, String(tr.transactionId), t);
    });
  }

  /** App Store Server Notifications V2. Idempotent by notificationUUID; unknown subscriptions are ignored (a purchase is attached by the app first). */
  async handleNotification(signedPayload) {
    if (!this.verifier) throw new GatewayError('feature_unavailable', 503);
    let n;
    try { n = await this.verifier.verifyAndDecodeNotification(signedPayload); } catch { throw new GatewayError('invalid_notification', 400); }
    const seen = this.db.prepare('SELECT 1 FROM apple_notifications WHERE uuid=?').get(n.notificationUUID);
    if (seen) return { duplicate: true };
    let tr = null, renewal = null;
    if (n.data?.signedTransactionInfo) tr = await this.verifier.verifyAndDecodeTransaction(n.data.signedTransactionInfo);
    if (n.data?.signedRenewalInfo) renewal = await this.verifier.verifyAndDecodeRenewalInfo(n.data.signedRenewalInfo);
    if (tr) {
      const row = this.db.prepare('SELECT account_id FROM subscriptions WHERE original_transaction_id=?').get(String(tr.originalTransactionId))
        ?? (tr.appAccountToken ? this.db.prepare('SELECT id AS account_id FROM accounts WHERE apple_account_token=?').get(tr.appAccountToken.toLowerCase()) : null);
      if (row) {
        const patch = {};
        switch (n.notificationType) {
          case 'REFUND': patch.status = 'refunded'; break;
          case 'REVOKE': patch.status = 'revoked'; break;
          case 'EXPIRED': case 'GRACE_PERIOD_EXPIRED': patch.status = 'expired'; break;
          case 'DID_FAIL_TO_RENEW': patch.status = n.subtype === 'GRACE_PERIOD' ? 'grace' : 'billing_retry'; break;
          case 'SUBSCRIBED': case 'DID_RENEW': case 'OFFER_REDEEMED': patch.status = tr.expiresDate > this.now() ? 'active' : 'expired'; break;
        }
        if (renewal && renewal.autoRenewStatus !== undefined) patch.autoRenew = renewal.autoRenewStatus === 1 ? 1 : 0;
        if (n.notificationType === 'DID_CHANGE_RENEWAL_STATUS' && patch.autoRenew === undefined) patch.autoRenew = n.subtype === 'AUTO_RENEW_ENABLED' ? 1 : 0;
        if (patch.status === 'grace' && renewal?.gracePeriodExpiresDate) tr = { ...tr, expiresDate: Math.max(tr.expiresDate ?? 0, renewal.gracePeriodExpiresDate) };
        this.record(row.account_id, tr, patch);
      }
    }
    this.db.prepare('INSERT INTO apple_notifications(uuid,type,subtype,received_at) VALUES(?,?,?,?)').run(n.notificationUUID, n.notificationType, n.subtype ?? null, this.now());
    return { duplicate: false, type: n.notificationType };
  }
}
