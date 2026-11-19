import { homedir, hostname, networkInterfaces } from 'node:os';
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { MODES } from './policy.mjs';
import { CloudAccess, GatewayModelClient } from './cloud.mjs';
import { ITalkAgentBackend } from './agent/loop.mjs';
import { OllamaAccess, OllamaModelClient } from './ollama.mjs';

export const DEFAULT_PORT = 47321;
export const stateDirDefault = () => path.join(homedir(), 'Library', 'Application Support', 'iTalk Agent');
export const logDirDefault = () => path.join(homedir(), 'Library', 'Logs', 'iTalk Agent');

const DEFAULTS = {
  name: null, port: DEFAULT_PORT, publicUrls: [], roots: ['~'], maxPermissionMode: 'ask', approvalTimeoutMinutes: 30, retentionDays: 30, maxConcurrentTasks: 2, maxSteps: 60,
};

export function loadConfig(dir) {
  const file = path.join(dir, 'config.json');
  let stored = {};
  if (existsSync(file)) { try { stored = JSON.parse(readFileSync(file, 'utf8')); } catch (error) { throw new Error(`config.json is not valid JSON: ${error.message}`); } }
  const config = { ...DEFAULTS, ...stored };
  delete config.backends;                        // older versions let a computer be pointed at other model servers; that is no longer possible
  if (!MODES.includes(config.maxPermissionMode)) throw new Error(`maxPermissionMode must be one of ${MODES.join(', ')}`);
  config.name ??= computerName();
  return config;
}

export function saveConfig(dir, config) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, 'config.json');
  writeFileSync(file, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
  chmodSync(file, 0o600);
}

export function computerName() {
  try { return execFileSync('scutil', ['--get', 'ComputerName'], { encoding: 'utf8', timeout: 2000 }).trim() || hostname(); } catch { return hostname(); }
}

// CONTEXT MEMORY
// Updated: 2026-11-02
// Status: inferred
// Why: Tailscale provides an existing private route when the phone is away from the LAN.
// Debug Goal: Advertise only this computer's active tailnet address without changing its network setup.
// Search Tags: tailscale ip pairing private network endpoints
// Invariants:
// - Never start, configure or expose a Tailscale service automatically.
// - Preserve the existing TLS certificate pin and phone signature on every request.
// Failure Modes:
// - An arbitrary public or malformed address is advertised as a private tailnet.
export function tailscaleIPv4({ run = (file, args) => execFileSync(file, args, { encoding: 'utf8', timeout: 1500, stdio: ['ignore', 'pipe', 'ignore'] }), candidates = ['/opt/homebrew/bin/tailscale', '/usr/local/bin/tailscale', '/Applications/Tailscale.app/Contents/MacOS/Tailscale', '/usr/bin/tailscale'], exists = existsSync } = {}) {
  for (const file of candidates) {
    if (!exists(file)) continue;
    try {
      const ip = run(file, ['ip', '-4']).trim();
      if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip)) continue;
      const parts = ip.split('.').map(Number);
      if (parts.length === 4 && parts.every(n => Number.isInteger(n) && n >= 0 && n <= 255) && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) return ip;
    } catch { /* Not installed, connected or available to this user. */ }
  }
  return null;
}

/** Where the phone can reach this computer: current LAN addresses, the .local name (survives address changes), and any public URLs configured. */
export function endpoints({ port, publicUrls = [], tailnetAddress = tailscaleIPv4() }) {
  const out = [];
  let local = null;
  try { local = execFileSync('scutil', ['--get', 'LocalHostName'], { encoding: 'utf8', timeout: 2000 }).trim(); } catch {}
  if (local) out.push(`https://${local}.local:${port}`);
  const priority = (name) => (name.startsWith('en') ? 0 : 1);
  const lan = [];
  for (const [name, list] of Object.entries(networkInterfaces())) for (const a of list ?? []) if (a.family === 'IPv4' && !a.internal && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address)) lan.push({ name, address: a.address });
  lan.sort((a, b) => priority(a.name) - priority(b.name));
  for (const { address } of lan) out.push(`https://${address}:${port}`);
  if (tailnetAddress) out.push(`https://${tailnetAddress}:${port}`);
  for (const u of publicUrls) out.push(u.replace(/\/+$/, ''));
  return [...new Set(out)];
}

export function lanAddresses() {
  const out = [];
  for (const list of Object.values(networkInterfaces())) for (const a of list ?? []) if (a.family === 'IPv4' && !a.internal) out.push(a.address);
  return out;
}

export class SessionStore {
  constructor(db, now = () => Date.now()) { this.db = db; this.now = now; }
  load(id) { const row = this.db.prepare('SELECT data FROM backend_sessions WHERE id=?').get(id); return row ? JSON.parse(row.data) : null; }
  save(id, backend, data) { this.db.prepare('INSERT INTO backend_sessions(id,backend,data,updated_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at').run(id, backend, JSON.stringify(data), this.now()); }
  purge(olderThanMs) { return this.db.prepare('DELETE FROM backend_sessions WHERE updated_at<?').run(this.now() - olderThanMs).changes; }
}

/** Managed cloud access and an independently discovered, fixed-loopback local Ollama service. */
export async function createBackends(config, { db, home = homedir(), fetcher = fetch, localFetcher, stateDir, keychain, web, opener, sleep, now, log } = {}) {
  const sessions = new SessionStore(db);
  const access = new CloudAccess({ stateDir, keychain, fetcher });
  const client = new GatewayModelClient({ access, fetcher, sleep, log });
  const map = new Map();
  map.sessions = sessions; map.access = access;
  map.set('italk', new ITalkAgentBackend({ access, client, sessions, home, stateDir, web, opener, maxSteps: config.maxSteps, retentionMs: config.retentionDays * 86_400_000, now, log }));
  const localAccess = new OllamaAccess({ fetcher: localFetcher });
  map.set('ollama', new ITalkAgentBackend({ access: localAccess, client: new OllamaModelClient({ access: localAccess, fetcher: localFetcher }), sessions, home, stateDir, web, opener, maxSteps: config.maxSteps, retentionMs: config.retentionDays * 86_400_000, localOnly: true, now, log }));
  return map;
}
