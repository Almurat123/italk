import { createHash } from 'node:crypto';
import { AgentError } from './db.mjs';
import { verifySignature } from './identity.mjs';

// Every request after pairing is signed by the phone's Ed25519 key: no passwords or bearer tokens exist to be stolen from a log.
//   X-Italk-Key: <phone id>   X-Italk-Time: <ms>   X-Italk-Nonce: <random>   X-Italk-Sig: base64url(sign("<METHOD>\n<path+query>\n<time>\n<nonce>\n<sha256 hex of body>"))

export const SIGNING_WINDOW_MS = 90_000;
export const signingString = ({ method, path, time, nonce, body }) => `${method}\n${path}\n${time}\n${nonce}\n${createHash('sha256').update(body).digest('hex')}`;

export class RequestAuth {
  constructor({ db, now = () => Date.now() }) { this.db = db; this.now = now; this.seen = new Map(); }

  verify(req, bodyBuffer) {
    const id = req.headers['x-italk-key'], time = Number(req.headers['x-italk-time']), nonce = req.headers['x-italk-nonce'], sig = req.headers['x-italk-sig'];
    if (!id || !nonce || !sig || !Number.isFinite(time)) throw new AgentError('unauthorized', 401);
    if (Math.abs(this.now() - time) > SIGNING_WINDOW_MS) throw new AgentError('stale_request', 401);
    const phone = this.db.prepare('SELECT * FROM phones WHERE id=?').get(String(id));
    if (!phone) throw new AgentError('unknown_device', 401);
    if (phone.revoked_at) throw new AgentError('revoked', 403);
    const message = signingString({ method: req.method, path: req.url, time, nonce, body: bodyBuffer });
    if (!verifySignature(Buffer.from(phone.public_key, 'base64url'), message, Buffer.from(String(sig), 'base64url'))) throw new AgentError('bad_signature', 401);
    // Replay protection: a (device, nonce) pair is accepted once inside the signing window.
    const key = `${id}:${nonce}`;
    if (this.now() - (this.sweptAt ?? 0) > 1000) { this.sweptAt = this.now(); for (const [k, t] of this.seen) if (t < this.now() - SIGNING_WINDOW_MS * 2) this.seen.delete(k); }
    if (this.seen.has(key)) throw new AgentError('replayed_request', 401);
    this.seen.set(key, this.now());
    this.db.prepare('UPDATE phones SET last_seen=? WHERE id=?').run(this.now(), phone.id);
    return { phoneId: phone.id, phoneName: phone.name };
  }
}
