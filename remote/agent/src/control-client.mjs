import net from 'node:net';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { homedir, tmpdir } from 'node:os';

/** Unix socket paths are limited to ~103 bytes on macOS. A long state directory gets a short, per-user path (home first, then the temp dir) instead. */
export function controlSocketPath(stateDir) {
  const preferred = path.join(stateDir, 'control.sock');
  if (Buffer.byteLength(preferred) <= 100) return preferred;
  const name = `.italk-agent-${createHash('sha256').update(path.resolve(stateDir)).digest('hex').slice(0, 12)}.sock`;
  for (const dir of [homedir(), tmpdir(), '/tmp']) { const candidate = path.join(dir, name); if (Buffer.byteLength(candidate) <= 100) return candidate; }
  return preferred;
}

/** One request, one reply (first JSON line). */
export function controlRequest(stateDir, msg, { timeoutMs = 10_000 } = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(controlSocketPath(stateDir));
    let buf = '';
    const timer = setTimeout(() => { sock.destroy(); reject(Object.assign(new Error('The agent did not answer.'), { code: 'timeout' })); }, timeoutMs);
    sock.setEncoding('utf8');
    sock.on('connect', () => sock.write(JSON.stringify(msg) + '\n'));
    sock.on('data', (d) => { buf += d; const i = buf.indexOf('\n'); if (i >= 0) { clearTimeout(timer); sock.end(); try { resolve(JSON.parse(buf.slice(0, i))); } catch (e) { reject(e); } } });
    sock.on('error', (e) => { clearTimeout(timer); reject(Object.assign(new Error(e.code === 'ENOENT' || e.code === 'ECONNREFUSED' ? 'The iTalk agent is not running.' : e.message), { code: e.code === 'ENOENT' || e.code === 'ECONNREFUSED' ? 'not_running' : e.code })); });
  });
}

/** Long-lived session: `onMessage` gets every line; returns { send, close }. */
export function controlSession(stateDir, onMessage, onClose = () => {}) {
  const sock = net.createConnection(controlSocketPath(stateDir));
  let buf = '';
  sock.setEncoding('utf8');
  sock.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line.trim()) { try { onMessage(JSON.parse(line)); } catch {} } } });
  sock.on('close', onClose);
  return new Promise((resolve, reject) => {
    sock.once('connect', () => resolve({ send: (m) => sock.write(JSON.stringify(m) + '\n'), close: () => sock.end() }));
    sock.once('error', (e) => reject(Object.assign(new Error(e.code === 'ENOENT' || e.code === 'ECONNREFUSED' ? 'The iTalk agent is not running.' : e.message), { code: 'not_running' })));
  });
}
