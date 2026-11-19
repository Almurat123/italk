import { generateKeyPairSync, createPrivateKey, createPublicKey, createHash, sign, verify, X509Certificate, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

// Identity of this computer: a long-term Ed25519 key (signs the pairing transcript, proves "this is the computer from the QR") and a
// self-signed TLS certificate whose public-key hash travels in the QR code (the phone pins it; no certificate authority involved).

const b32 = (buf) => { const A = 'abcdefghijklmnopqrstuvwxyz234567'; let bits = '', out = ''; for (const b of buf) bits += b.toString(2).padStart(8, '0'); for (let i = 0; i + 5 <= bits.length; i += 5) out += A[parseInt(bits.slice(i, i + 5), 2)]; return out; };
export const sha256 = (data) => createHash('sha256').update(data).digest();
export const rawPublicKey = (keyObject) => createPublicKey(keyObject).export({ type: 'spki', format: 'der' }).subarray(-32);
export const deviceIdOf = (publicRaw) => b32(sha256(publicRaw)).slice(0, 16);
export const fingerprintOf = (publicRaw) => sha256(publicRaw).toString('hex').slice(0, 12).toUpperCase().match(/.{4}/g).join('-');

/** Wraps a raw 32-byte Ed25519 public key as a KeyObject. */
export function publicKeyFromRaw(raw) {
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  return createPublicKey({ key: Buffer.concat([prefix, raw]), format: 'der', type: 'spki' });
}

export function loadOrCreateIdentity(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const keyPath = join(dir, 'identity.key');
  let privateKey;
  if (existsSync(keyPath)) privateKey = createPrivateKey(readFileSync(keyPath));
  else {
    privateKey = generateKeyPairSync('ed25519').privateKey;
    writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    chmodSync(keyPath, 0o600);
  }
  const publicRaw = rawPublicKey(privateKey);
  return {
    privateKey, publicRaw, deviceId: deviceIdOf(publicRaw), fingerprint: fingerprintOf(publicRaw),
    sign: (message) => sign(null, Buffer.from(message), privateKey),
  };
}

export function verifySignature(publicRaw, message, signature) {
  try { return verify(null, Buffer.from(message), publicKeyFromRaw(publicRaw), signature); } catch { return false; }
}

/** Creates (once) the TLS key pair and returns { key, cert, pin } where pin = SHA-256 of the certificate (base64url). */
export function ensureTlsCertificate(dir, { hostnames = [], addresses = [] } = {}) {
  const keyPath = join(dir, 'tls.key'), certPath = join(dir, 'tls.crt');
  if (!existsSync(keyPath) || !existsSync(certPath)) {
    const san = ['DNS:localhost', 'IP:127.0.0.1', ...hostnames.map(h => `DNS:${h}`), ...addresses.map(a => `IP:${a}`)].join(',');
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-keyout', keyPath, '-out', certPath,
      '-days', '3650', '-subj', '/CN=iTalk Mac Agent', '-addext', `subjectAltName=${san}`], { stdio: 'ignore' });
    chmodSync(keyPath, 0o600);
  }
  const key = readFileSync(keyPath), cert = readFileSync(certPath);
  // The pin is the SHA-256 of the certificate itself (DER). The phone compares it with the one in the QR code; no certificate authority is involved.
  return { key, cert, pin: sha256(new X509Certificate(cert).raw).toString('base64url') };
}

export const randomToken = (bytes = 32) => randomBytes(bytes).toString('base64url');
