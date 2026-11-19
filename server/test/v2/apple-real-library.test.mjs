import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createSign, X509Certificate } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SignedDataVerifier, Environment } from '@apple/app-store-server-library';
import { loadAppleRoots } from '../../src/v2/apple.mjs';

// The injected fake verifier covers the gateway's own logic. These tests use Apple's REAL library and Apple's REAL root certificate to prove that
// the production wiring constructs and that a transaction not signed through Apple's chain is refused.

const b64u = (b) => Buffer.from(b).toString('base64url');

test('Apple root certificate on disk is the genuine G3 root', () => {
  const roots = loadAppleRoots(new URL('../../certs/apple', import.meta.url).pathname);
  assert.equal(roots.length, 1);
  const cert = new X509Certificate(roots[0]);
  assert.match(cert.subject, /Apple Root CA - G3/);
  assert.equal(cert.fingerprint256, '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79');
});

test('the production verifier refuses garbage and transactions signed by a certificate that does not chain to Apple', async () => {
  const roots = loadAppleRoots(new URL('../../certs/apple', import.meta.url).pathname);
  const verifier = new SignedDataVerifier(roots, false, Environment.SANDBOX, 'com.italk.assistant');
  await assert.rejects(verifier.verifyAndDecodeTransaction('not.a.jws'));
  await assert.rejects(verifier.verifyAndDecodeNotification('x.y.z'));
  // A well-formed ES256 JWS whose x5c chain is a self-made certificate (what a forged purchase looks like).
  const dir = mkdtempSync(join(tmpdir(), 'iap-'));
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'), '-days', '2', '-subj', '/CN=Forger'], { stdio: 'ignore' });
    const der = new X509Certificate(readFileSync(join(dir, 'c.pem'))).raw.toString('base64');
    const header = b64u(JSON.stringify({ alg: 'ES256', x5c: [der, der, der] }));
    const payload = b64u(JSON.stringify({ bundleId: 'com.italk.assistant', productId: 'com.italk.cloud.monthly', transactionId: '1', originalTransactionId: '1', environment: 'Sandbox', expiresDate: Date.now() + 86_400_000 }));
    const sig = createSign('SHA256').update(`${header}.${payload}`).sign({ key: readFileSync(join(dir, 'k.pem')), dsaEncoding: 'ieee-p1363' });
    await assert.rejects(verifier.verifyAndDecodeTransaction(`${header}.${payload}.${b64u(sig)}`), 'a forged purchase must not verify');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
