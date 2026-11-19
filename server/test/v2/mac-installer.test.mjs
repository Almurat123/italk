import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { openDb } from '../../src/v2/db.mjs';
import { createApp } from '../../src/v2/app.mjs';
import { Pricing } from '../../src/v2/plans.mjs';

// The one-line installer for the Mac companion and the program it downloads: public, checksummed, and tied to the configured public address.

const fast = { N: 1 << 10, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
async function boot(options = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'mac-'));
  const bytes = Buffer.from('not really a tarball but the bytes are checked all the same');
  writeFileSync(path.join(dir, 'italk-agent.tgz'), bytes);
  writeFileSync(path.join(dir, 'italk-agent.tgz.sha256'), createHash('sha256').update(bytes).digest('hex') + '\n');
  const db = openDb(':memory:');
  const app = createApp({ db, pricing: new Pricing(), provider: null, accountsOptions: { scryptParams: fast }, macDir: pathToFileURL(dir + '/'), ...options });
  await new Promise(r => app.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${app.server.address().port}`;
  return { base, bytes, dir, close: async () => { await app.close(); db.close(); rmSync(dir, { recursive: true, force: true }); } };
}

test('the installer carries the configured public address and nothing the requester typed', async (t) => {
  const g = await boot({ publicUrl: 'https://api.example.com' }); t.after(g.close);
  const res = await fetch(g.base + '/mac/install.sh', { headers: { host: 'evil.example:1; rm -rf ~' } }).catch(() => null);
  const text = res ? await res.text() : '';
  assert.ok(!text.includes('rm -rf ~') || !res.ok);
  const ok = await fetch(g.base + '/mac/install.sh');
  assert.equal(ok.status, 200); assert.match(ok.headers.get('content-type'), /shellscript/);
  const script = await ok.text();
  assert.match(script, /^#!\/bin\/sh/); assert.match(script, /GATEWAY="https:\/\/api\.example\.com"/); assert.doesNotMatch(script, /__GATEWAY__/);
  assert.match(script, /shasum -a 256/, 'every download is checked'); assert.match(script, /\/dev\/tty/, 'the pairing question is answered on the keyboard');
});

test('a loopback development gateway may use the address it was reached at; any other gateway needs a configured public address', async (t) => {
  const dev = await boot(); t.after(dev.close);
  const script = await (await fetch(dev.base + '/mac/install.sh')).text();
  assert.ok(script.includes(`GATEWAY="${dev.base}"`));
  const bad = await boot({ publicUrl: 'https://x.example.com/path?q=$(id)' }); t.after(bad.close);
  assert.equal((await fetch(bad.base + '/mac/install.sh', { headers: { host: 'public.example.com' } })).status, 503, 'no usable address: refuse instead of guessing');
});

test('the program and its checksum are served, and the checksum matches', async (t) => {
  const g = await boot({ publicUrl: 'https://api.example.com' }); t.after(g.close);
  const tgz = Buffer.from(await (await fetch(g.base + '/mac/italk-agent.tgz')).arrayBuffer());
  const sum = (await (await fetch(g.base + '/mac/italk-agent.tgz.sha256')).text()).trim();
  assert.deepEqual(tgz, g.bytes); assert.equal(sum, createHash('sha256').update(tgz).digest('hex'));
  assert.equal((await fetch(g.base + '/mac/version.json')).status, 503, 'a file that was not built is reported, not invented');
  for (const odd of ['/mac/../../etc/passwd', '/mac/other.txt', '/mac/install.sh/../x']) assert.ok([401, 404].includes((await fetch(g.base + odd)).status), `${odd} is not served`);
});
