#!/usr/bin/env node
// Builds what the gateway serves to a Mac at /mac/*: the agent program (a few hundred KB, no models) as a tarball with its checksum.
//   node scripts/package-mac-companion.mjs            → server/public/mac/italk-agent.tgz (+ .sha256, version.json)
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, cpSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const agent = path.join(root, 'remote', 'agent');
const out = path.join(root, 'server', 'public', 'mac');
const version = readFileSync(path.join(agent, 'src', 'version.mjs'), 'utf8').match(/'([^']+)'/)[1];

const stage = mkdtempSync(path.join(tmpdir(), 'italk-pack-'));
try {
  for (const entry of ['package.json', 'bin', 'src', 'skills']) cpSync(path.join(agent, entry), path.join(stage, entry), { recursive: true });
  // the one runtime dependency (QR code in the terminal), without its own tests/docs
  const qr = path.join(agent, 'node_modules', 'qrcode-terminal');
  if (!existsSync(qr)) throw new Error('run `npm install` in remote/agent first');
  cpSync(qr, path.join(stage, 'node_modules', 'qrcode-terminal'), { recursive: true, filter: (p) => !/\/(test|example|\.git)(\/|$)/.test(p) });
  writeFileSync(path.join(stage, 'VERSION'), version + '\n');
  mkdirSync(out, { recursive: true });
  const file = path.join(out, 'italk-agent.tgz');
  execFileSync('tar', ['-czf', file, '--no-xattrs', '-C', stage, '.'], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
  const sha = createHash('sha256').update(readFileSync(file)).digest('hex');
  writeFileSync(`${file}.sha256`, `${sha}\n`);
  writeFileSync(path.join(out, 'version.json'), JSON.stringify({ version, sha256: sha, builtAt: new Date().toISOString() }, null, 2) + '\n');
  console.log(`packaged ${file}  ${(readFileSync(file).length / 1024).toFixed(0)} KB  v${version}  sha256 ${sha.slice(0, 12)}…`);
} finally { rmSync(stage, { recursive: true, force: true }); }
