#!/usr/bin/env node
// Development only: a throw-away gateway for trying the cloud path end to end from the iOS Simulator (or a Mac agent) with the real model.
//
//   node tools/dev-sim-gateway.mjs            # prints one JSON line with the endpoint and a subscribed test account, then keeps running
//
// Then, in another terminal, launch the Debug simulator build against it and sign in with the printed account:
//   SIMCTL_CHILD_ITALK_CLOUD_ENDPOINT=<endpoint> xcrun simctl launch <simulator> com.italk.assistant
//   (or write `italk.cloud.endpoint.override` into the app container's preferences: the app reads either in Debug builds only)
//
// The model key is read from server/.env by the gateway process itself and is never printed or written anywhere else. The database lives
// in a temporary folder that is deleted when this script stops. Real model calls cost real (small) money. Listens on 127.0.0.1 only.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.env.NODE_ENV === 'production') { console.error('refused: production'); process.exit(1); }
const here = path.dirname(fileURLToPath(import.meta.url));
const server = path.join(here, '..');
const envFile = path.join(server, '.env');
const freePort = () => new Promise((resolve, reject) => { const s = createServer(); s.once('error', reject); s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); }); });

const dir = mkdtempSync(path.join(tmpdir(), 'italk-sim-gateway-'));
const db = path.join(dir, 'gateway.sqlite');
const port = await freePort();
const endpoint = `http://127.0.0.1:${port}`;
const args = [...(existsSync(envFile) ? [`--env-file=${envFile}`] : []), path.join(server, 'src/v2/main.mjs')];
const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', ...args], {
  cwd: server, stdio: ['ignore', 'ignore', 'inherit'], env: { ...process.env, V2_HOST: '127.0.0.1', V2_PORT: String(port), DB_PATH: db, MAIL_MODE: 'console', NODE_ENV: 'development' },
});
const stop = (code = 0) => { try { child.kill('SIGTERM'); } catch {} setTimeout(() => { rmSync(dir, { recursive: true, force: true }); process.exit(code); }, 300); };
process.on('SIGINT', () => stop()); process.on('SIGTERM', () => stop()); child.on('exit', (code) => { if (code) { console.error(`gateway exited with ${code}`); stop(code); } });

for (let i = 0; ; i++) {
  try { if ((await fetch(`${endpoint}/v2/health`)).ok) break; } catch {}
  if (i > 60) { console.error('the gateway did not start'); stop(1); await new Promise(() => {}); }
  await new Promise(r => setTimeout(r, 250));
}
const email = `sim-${Date.now()}@example.com`, password = 'sim-password-123';
const reg = await fetch(`${endpoint}/v2/auth/register`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password, displayName: 'Sim QA' }) });
if (reg.status !== 201) { console.error(`registration failed: ${reg.status}`); stop(1); await new Promise(() => {}); }
execFileSync(process.execPath, ['--disable-warning=ExperimentalWarning', path.join(here, 'dev-grant.mjs'), db, email], { stdio: 'ignore' });
const caps = await (await fetch(`${endpoint}/v2/capabilities`)).json().catch(() => ({}));
const models = await (await fetch(`${endpoint}/v2/models`)).json().catch(() => ({ models: [] }));
console.log(JSON.stringify({ endpoint, email, password, subscription: 'granted (30 days, dev)', models: (models.models ?? []).map(m => m.id), modelKey: existsSync(envFile) ? 'from server/.env' : 'none (no server/.env: model calls will fail)', environment: caps.environment }));
console.error('Gateway running. Stop with Ctrl-C (the temporary database is removed).');
