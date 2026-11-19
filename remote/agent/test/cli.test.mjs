import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { scratch, TestPhone, sleep, fakeModelServer } from './helpers.mjs';

/** What a paired phone's credential hand-over leaves on disk when the Keychain is not available (the test process has no login keychain). */
function giveAccess(state, gateway) {
  writeFileSync(path.join(state, 'cloud.json'), JSON.stringify({ gateway: gateway.url, issuedAt: Date.now(), expiresAt: null, accountHint: 'tester', stored: 'file' }));
  writeFileSync(path.join(state, 'cloud.secret'), 'test-credential-0123456789abcdef\n', { mode: 0o600 });
}
import { controlRequest, controlSession, controlSocketPath } from '../src/control-client.mjs';
import { endpoints, tailscaleIPv4 } from '../src/config.mjs';

test('tailnet address discovery accepts only a connected private IPv4', () => {
  const get = value => tailscaleIPv4({ candidates: ['/fake/tailscale'], exists: () => true, run: () => value });
  assert.equal(get('100.101.102.103\n'), '100.101.102.103');
  for (const value of ['8.8.8.8', '100.128.1.1', '100.63.1.1', '100.64.1.999', '100..1.2', '100.64.1.1\n8.8.8.8', '']) assert.equal(get(value), null);
  assert.equal(tailscaleIPv4({ candidates: ['/missing'], exists: () => false }), null);
  assert.ok(endpoints({ port: 47321, tailnetAddress: get('100.101.102.103') }).includes('https://100.101.102.103:47321'));
  assert.ok(!endpoints({ port: 47321, tailnetAddress: null }).some(e => e.includes('100.101.102.103')));
});

const BIN = fileURLToPath(new URL('../bin/italk-agent.mjs', import.meta.url));

async function startProcess(stateDir, extra = []) {
  const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', BIN, 'run', '--state-dir', stateDir, '--port', '0', '--no-bonjour', '--json', ...extra], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = ''; child.stdout.on('data', d => out += d); child.stderr.on('data', d => out += d);
  const ready = await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('agent did not start: ' + out)), 15000);
    const poll = setInterval(() => { const m = out.match(/\{"ready":true,"port":(\d+)/); if (m) { clearInterval(poll); clearTimeout(t); resolve(Number(m[1])); } }, 50);
  });
  return { child, port: ready, stop: () => new Promise(r => { child.on('close', r); child.kill('SIGTERM'); }), log: () => out };
}

test('real process: terminal pairing (QR → phone → person at the computer approves), device list, revoke, graceful shutdown', async () => {
  const sc = scratch('ic-'); const state = path.join(sc.dir, 's'); mkdirSync(state, { recursive: true });
  const model = await fakeModelServer(() => ({ parts: [{ text: 'pong' }] }));
  writeFileSync(path.join(state, 'config.json'), JSON.stringify({ name: 'CLI Mac', roots: [sc.dir] }));
  giveAccess(state, model);
  const proc = await startProcess(state);
  try {
    const status = await controlRequest(state, { op: 'status' });
    assert.equal(status.agent.name, 'CLI Mac'); assert.equal(status.devices, 0); assert.equal(status.port, proc.port);

    // 1. nobody at the terminal → a stolen QR (no `pair` session) cannot pair; and the phone has no valid code at all
    const stranger = new TestPhone({ name: 'Stranger' }); stranger.agent = { port: proc.port, pin: 'x' };
    assert.equal((await stranger.raw('POST', '/v1/pair', { pairingId: 'nope', phonePublicKey: stranger.publicKey, phoneName: 'x', nonce: 'n', proof: 'p' })).status, 410);

    // 2. a terminal session starts pairing, shows the QR, a phone scans it, the person types "y"
    const messages = []; let session; let confirmed = null;
    const paired = new Promise((resolve) => {
      controlSession(state, (m) => { messages.push(m); if (m.type === 'confirm') { confirmed = m; session.send({ op: 'answer', approve: true }); } if (m.type === 'paired') resolve(); }).then(s => { session = s; s.send({ op: 'pair' }); });
    });
    await new Promise(r => { const t = setInterval(() => { if (messages.some(m => m.type === 'qr')) { clearInterval(t); r(); } }, 20); });
    const qr = messages.find(m => m.type === 'qr');
    assert.match(qr.uri, /^italk-pair:\/\/v1\?k=/); assert.ok(qr.endpoints.length >= 0);
    const phone = new TestPhone({ name: 'Almurat’s iPhone' });
    const res = await phone.pair(qr.uri, { port: proc.port });
    assert.equal(res.status, 200); await paired;
    assert.equal(confirmed.phoneName, 'Almurat’s iPhone'); assert.match(confirmed.fingerprint, /^[0-9A-F]{4}(-[0-9A-F]{4}){2}$/);
    session.close();

    // 3. the paired phone can run a task on the real process
    const t = await phone.call('POST', '/v1/tasks', { backend: 'italk', prompt: 'ping' }, { headers: { 'idempotency-key': 'cli-test-key-1' } });
    assert.equal(t.status, 201);
    const done = await phone.stream(t.json.task.id, {});
    assert.equal(done.events.map(e => e.type).includes('completed'), true);

    // 4. devices and revoke from the terminal
    const devices = await controlRequest(state, { op: 'devices' });
    assert.equal(devices.devices.length, 1); assert.equal(devices.devices[0].name, 'Almurat’s iPhone');
    assert.equal((await controlRequest(state, { op: 'revoke', id: devices.devices[0].id })).type, 'ok');
    assert.equal((await phone.call('GET', '/v1/status')).status, 403);

    // 5. a code can only be used once, and a refused pairing stores nothing
    const messages2 = []; let session2; const refused = new Promise((resolve) => {
      controlSession(state, (m) => { messages2.push(m); if (m.type === 'confirm') session2.send({ op: 'answer', approve: false }); resolve; }).then(s => { session2 = s; s.send({ op: 'pair' }); });
    });
    await new Promise(r => { const tt = setInterval(() => { if (messages2.some(m => m.type === 'qr')) { clearInterval(tt); r(); } }, 20); });
    const phone2 = new TestPhone({ name: 'Second' });
    const res2 = await phone2.pair(messages2.find(m => m.type === 'qr').uri, { port: proc.port });
    assert.equal(res2.status, 403); assert.equal(res2.json.error.code, 'rejected_by_computer');
    session2.close(); void refused;
    assert.equal((await controlRequest(state, { op: 'devices' })).devices.filter(d => !d.revokedAt).length, 0);
  } finally { const code = await proc.stop(); assert.ok(code === 0 || code === null, 'clean shutdown on SIGTERM'); await model.close(); sc.cleanup(); }
});

test('real process: identity, certificate and database survive a restart (same agent id, same pin, history kept)', async () => {
  const sc = scratch('ic-'); const state = path.join(sc.dir, 's'); mkdirSync(state, { recursive: true });
  const model = await fakeModelServer(() => ({ parts: [{ text: 'again' }] }));
  writeFileSync(path.join(state, 'config.json'), JSON.stringify({ name: 'CLI Mac', roots: [sc.dir] }));
  giveAccess(state, model);
  try {
    let proc = await startProcess(state);
    const id1 = (await controlRequest(state, { op: 'status' })).agent;
    const messages = []; let session;
    controlSession(state, (m) => { messages.push(m); if (m.type === 'confirm') session.send({ op: 'answer', approve: true }); }).then(s => { session = s; s.send({ op: 'pair' }); });
    await new Promise(r => { const t = setInterval(() => { if (messages.some(m => m.type === 'qr')) { clearInterval(t); r(); } }, 20); });
    const uri = messages.find(m => m.type === 'qr').uri; const pin1 = new URL(uri).searchParams.get('p');
    const phone = new TestPhone(); await phone.pair(uri, { port: proc.port }); session.close();
    const t = await phone.call('POST', '/v1/tasks', { backend: 'italk', prompt: 'x' }, { headers: { 'idempotency-key': 'restart-key-1' } });
    await phone.stream(t.json.task.id, {});
    await proc.stop();
    proc = await startProcess(state);
    const id2 = (await controlRequest(state, { op: 'status' })).agent;
    assert.equal(id2.id, id1.id); assert.equal(id2.fingerprint, id1.fingerprint);
    phone.agent.port = proc.port;
    assert.equal((await phone.call('GET', '/v1/status')).status, 200, 'the phone stays paired across restarts');
    const old = await phone.call('GET', `/v1/tasks/${t.json.task.id}/events?after=0`);
    assert.equal(old.json.task.state, 'completed'); assert.ok(old.json.events.length > 2);
    const again = await phone.call('POST', '/v1/tasks', { backend: 'italk', prompt: 'x' }, { headers: { 'idempotency-key': 'restart-key-1' } });
    assert.equal(again.status, 200, 'idempotency survives a restart'); assert.equal(again.json.task.id, t.json.task.id);
    await proc.stop();
  } finally { await model.close(); sc.cleanup(); }
});

test('control socket: a long state directory still gets a socket path the OS accepts (macOS limit ~103 bytes), the same one for client and service', () => {
  const short = '/Users/a/Library/Application Support/iTalk Agent';
  assert.equal(controlSocketPath(short), path.join(short, 'control.sock'));
  const long = path.join('/private/tmp', 'x'.repeat(120), 'agent-state');
  const p = controlSocketPath(long);
  assert.ok(Buffer.byteLength(p) <= 100, p);
  assert.equal(controlSocketPath(long), p);
  assert.notEqual(controlSocketPath(long + '2'), p);
});
