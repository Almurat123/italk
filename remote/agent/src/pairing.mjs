import { createHmac, timingSafeEqual } from 'node:crypto';
import { AgentError, tx } from './db.mjs';
import { deviceIdOf, fingerprintOf, randomToken, verifySignature } from './identity.mjs';

// QR pairing. The QR code carries everything the phone needs to talk to THIS computer and nobody else: its identity key, the pinned TLS
// key, where to reach it, and a one-time secret. A photo of the QR code is therefore as sensitive as a password for five minutes.
//
//   phone → POST /pair { pairingId, phonePublicKey, phoneName, nonce, proof = HMAC-SHA256(secret, "pair|" + pairingId + "|" + phonePublicKey + "|" + nonce) }
//   computer: checks proof (one attempt per code, five minutes), then asks the PERSON AT THE COMPUTER to approve this phone by name and
//   fingerprint; only then is the phone stored and the computer's Ed25519 signature over the transcript returned (the phone verifies it
//   against the identity key from the QR: proof that it reached the computer that displayed the code).

export const PAIRING_TTL_MS = 5 * 60_000;

export function pairingTranscript({ pairingId, phonePublicKey, agentDeviceId, nonce }) { return `italk-pairing-v1|${pairingId}|${phonePublicKey}|${agentDeviceId}|${nonce}`; }

export class Pairing {
  constructor({ db, identity, tls, endpoints, name, approve, now = () => Date.now() }) { Object.assign(this, { db, identity, tls, endpoints, name, approve, now }); this.open = new Map(); }

  /** Starts a pairing and returns the payload to show as a QR code. Only one code is valid at a time.
   *  The link is kept short (QR density): key, certificate pin, one-time id and secret, name, and `host:port` endpoints. */
  begin() {
    this.open.clear();
    const pairingId = randomToken(16), secret = randomToken(16), expiresAt = this.now() + PAIRING_TTL_MS;
    this.open.set(pairingId, { secret, expiresAt, used: false });
    const endpoints = this.endpoints.map(e => e.replace(/^https:\/\//, '').replace(/\/+$/, '')).map(e => (/:\d+$/.test(e) ? e : `${e}:443`));
    const pairs = [['k', this.identity.publicRaw.toString('base64url')], ['p', this.tls.pin], ['i', pairingId], ['s', secret], ['n', this.name], ...endpoints.map(e => ['e', e])];
    const payload = { key: pairs[0][1], pin: this.tls.pin, pairingId, secret, name: this.name, endpoints };
    return { payload, uri: `italk-pair://v1?${pairs.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&')}`, expiresAt };
  }

  async complete(body) {
    const { pairingId, phonePublicKey, phoneName, nonce, proof } = body ?? {};
    const session = this.open.get(pairingId);
    if (!session || session.used || session.expiresAt <= this.now()) throw new AgentError('pairing_expired', 410);
    session.used = true;                                               // one attempt per code, whatever happens next
    this.open.delete(pairingId);
    if (typeof phonePublicKey !== 'string' || typeof nonce !== 'string' || typeof proof !== 'string' || typeof phoneName !== 'string') throw new AgentError('invalid_arguments');
    const expected = createHmac('sha256', session.secret).update(`pair|${pairingId}|${phonePublicKey}|${nonce}`).digest();
    const supplied = Buffer.from(proof, 'base64url');
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) throw new AgentError('invalid_proof', 403);
    const raw = Buffer.from(phonePublicKey, 'base64url');
    if (raw.length !== 32) throw new AgentError('invalid_arguments');
    const phoneId = deviceIdOf(raw), name = phoneName.trim().slice(0, 60) || 'iPhone';
    const approved = await this.approve({ phoneId, name, fingerprint: fingerprintOf(raw) });
    if (!approved) throw new AgentError('rejected_by_computer', 403);
    tx(this.db, () => this.db.prepare(`INSERT INTO phones(id,name,public_key,paired_at) VALUES(?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name, public_key=excluded.public_key, paired_at=excluded.paired_at, revoked_at=NULL`).run(phoneId, name, phonePublicKey, this.now()));
    const signature = this.identity.sign(pairingTranscript({ pairingId, phonePublicKey, agentDeviceId: this.identity.deviceId, nonce }));
    return { phoneId, agentId: this.identity.deviceId, signature: signature.toString('base64url') };
  }
}

/** Phone side of the transcript check, kept here so tests exercise both halves. */
export function verifyPairingResponse({ agentPublicKey, pairingId, phonePublicKey, agentDeviceId, nonce, signature }) {
  return verifySignature(Buffer.from(agentPublicKey, 'base64url'), pairingTranscript({ pairingId, phonePublicKey, agentDeviceId, nonce }), Buffer.from(signature, 'base64url'));
}
