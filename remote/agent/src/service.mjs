import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { stateDirDefault, logDirDefault } from './config.mjs';

// launchd integration. The agent runs as the user's LaunchAgent so it survives closing the terminal, restarts after a crash, and starts at login.
// macOS protects ~/Documents, ~/Desktop and ~/Downloads from background processes, so the service runs a *copy* of the code kept in the state folder.

export const LABEL = 'app.italk.agent';
export const plistPath = (home = homedir()) => path.join(home, 'Library', 'LaunchAgents', `${LABEL}.plist`);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function renderPlist({ node, script, logFile, home = homedir(), pathEnv }) {
  const args = [node, '--disable-warning=ExperimentalWarning', script, 'run'];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>${args.map(a => `<string>${esc(a)}</string>`).join('')}</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>WorkingDirectory</key><string>${esc(home)}</string>
  <key>StandardOutPath</key><string>${esc(logFile)}</string>
  <key>StandardErrorPath</key><string>${esc(logFile)}</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${esc(pathEnv)}</string><key>HOME</key><string>${esc(home)}</string></dict>
</dict>
</plist>
`;
}

/** A Node that will still be there next year: Homebrew's links are preferred over a copy bundled inside another tool (nvm, Hermes, an IDE) that may be updated away. */
export function pickNode(current = process.execPath) {
  const ok = (bin) => { try { const [major, minor] = execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000 }).trim().slice(1).split('.').map(Number); return major > 22 || (major === 22 && minor >= 13); } catch { return false; } };
  for (const candidate of ['/opt/homebrew/bin/node', '/usr/local/bin/node']) if (existsSync(candidate) && ok(candidate)) return candidate;
  return current;
}

export function installService({ stateDir = stateDirDefault(), home = homedir(), node = pickNode(), load = true } = {}) {
  const appDir = path.join(stateDir, 'app');
  mkdirSync(appDir, { recursive: true, mode: 0o700 });
  // When the installer already unpacked the program into the app folder, that folder is the source: copying it onto itself would delete it.
  if (path.resolve(packageRoot) !== path.resolve(appDir)) for (const entry of ['package.json', 'bin', 'src', 'skills', 'node_modules']) {
    const from = path.join(packageRoot, entry);
    if (!existsSync(from)) continue;
    rmSync(path.join(appDir, entry), { recursive: true, force: true });
    cpSync(from, path.join(appDir, entry), { recursive: true });
  }
  const logDir = logDirDefault(); mkdirSync(logDir, { recursive: true });
  const pathEnv = [path.dirname(node), '/opt/homebrew/bin', '/usr/local/bin', path.join(home, '.local/bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin', ...(process.env.PATH ?? '').split(':')].filter((p, i, a) => p && a.indexOf(p) === i).join(':');
  const file = plistPath(home);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, renderPlist({ node, script: path.join(appDir, 'bin', 'italk-agent.mjs'), logFile: path.join(logDir, 'agent.log'), home, pathEnv }));
  if (load) {
    const domain = `gui/${process.getuid()}`;
    unload(domain);
    // `bootout` returns before launchd has finished tearing the job down; bootstrapping at once fails with "Input/output error".
    let lastError;
    for (let attempt = 0; attempt < 10; attempt++) {
      try { execFileSync('launchctl', ['bootstrap', domain, file], { stdio: 'pipe' }); lastError = null; break; }
      catch (error) { lastError = error; sleepSync(500); unload(domain); }
    }
    if (lastError) throw lastError;
    execFileSync('launchctl', ['kickstart', '-k', `${domain}/${LABEL}`], { stdio: 'pipe' });
  }
  return { plist: file, appDir, logFile: path.join(logDir, 'agent.log') };
}

export function uninstallService({ home = homedir() } = {}) {
  unload(`gui/${process.getuid()}`);
  rmSync(plistPath(home), { force: true });
}

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/** Stops the job and waits (up to ~5 s) until launchd no longer knows it. */
function unload(domain) {
  try { execFileSync('launchctl', ['bootout', `${domain}/${LABEL}`], { stdio: 'ignore' }); } catch { return; }
  for (let i = 0; i < 25; i++) {
    try { execFileSync('launchctl', ['print', `${domain}/${LABEL}`], { stdio: 'ignore' }); } catch { return; }
    sleepSync(200);
  }
}

export function serviceLoaded() {
  try { execFileSync('launchctl', ['print', `gui/${process.getuid()}/${LABEL}`], { stdio: 'ignore' }); return true; } catch { return false; }
}
