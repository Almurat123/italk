import { homedir } from 'node:os';
import { realpathSync, existsSync } from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// What the phone may ask this computer to do, decided here and never by the model or the phone.
//
//   readOnly    reads files inside the allowed roots; no edits, no commands except a fixed list of read-only ones
//   ask         (default) reads inside the roots run; every edit and every other command is shown on the phone first
//   acceptEdits edits inside the task's workspace run; other commands run in a sandbox (no network, writes only in the workspace)
//   auto        like acceptEdits, edits allowed anywhere inside the roots
//
// The Mac's own configuration caps the mode a phone may choose (`maxPermissionMode`, default `ask`). Credentials, keys, browser
// profiles and this agent's own state are never readable by any mode.

export const MODES = ['readOnly', 'ask', 'acceptEdits', 'auto'];
export const modeRank = (mode) => MODES.indexOf(mode);
export const clampMode = (requested, max) => (modeRank(requested) < 0 ? 'ask' : modeRank(requested) <= modeRank(max) ? requested : max);

export const expandHome = (p, home = homedir()) => (p === '~' ? home : p.startsWith('~/') ? path.join(home, p.slice(2)) : p);

const HOME_DENY = ['.ssh', '.gnupg', '.aws', '.azure', '.kube', '.config/gcloud', '.config/gh', '.docker/config.json', '.netrc', '.npmrc', '.pypirc', '.git-credentials',
  '.claude', '.codex', '.hermes', 'Library/Keychains', 'Library/Cookies', 'Library/Safari', 'Library/Messages', 'Library/Mail', 'Library/Application Support/Google/Chrome',
  'Library/Application Support/Firefox', 'Library/Application Support/Microsoft Edge', 'Library/Application Support/BraveSoftware', 'Library/Application Support/AddressBook',
  'Library/Application Support/com.apple.TCC', 'Library/Application Support/Claude', 'Library/Application Support/iTalk Agent', 'Library/Group Containers/group.com.apple.notes',
  '.config/google-chrome', '.config/chromium', '.config/BraveSoftware', '.config/microsoft-edge', '.config/opera', '.mozilla',
  '.local/share/keyrings', '.local/share/italk-agent', '.local/state/italk-agent',
  'AppData/Local/Google/Chrome', 'AppData/Local/Microsoft/Edge', 'AppData/Local/BraveSoftware', 'AppData/Roaming/Mozilla/Firefox'];
const SYSTEM_DENY = ['/etc/sudoers', '/etc/sudoers.d', '/private/etc/sudoers', '/private/etc/sudoers.d', '/private/var/db', '/Library/Keychains', '/System'];
const NAME_DENY = [/^\.env(\..+)?$/i, /\.(pem|p12|pfx|key|keychain|keychain-db|jks|kdbx)$/i, /^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$/i, /^(credentials|secrets?)\.(json|ya?ml|toml)$/i, /\.mobileconfig$/i];
const NAME_ALLOW = [/^\.env\.(example|sample|template|dist)$/i];

const inside = (child, parent) => child === parent || child.startsWith(parent.endsWith(path.sep) ? parent : parent + path.sep);

/** Resolves symlinks for the part of the path that exists, so a link inside an allowed folder cannot lead out of it. */
export function realish(p) {
  let current = path.resolve(p), tail = '';
  for (;;) {
    if (existsSync(current)) { try { return path.join(realpathSync.native(current), tail); } catch { return path.join(current, tail); } }   // native: the on-disk spelling (macOS volumes ignore case)
    const parent = path.dirname(current);
    if (parent === current) return path.join(current, tail);
    tail = path.join(path.basename(current), tail); current = parent;
  }
}

export class PathPolicy {
  constructor({ roots = [homedir()], home = homedir(), extraDeny = [] } = {}) {
    this.home = realish(home);
    this.roots = roots.map(r => realish(expandHome(r, home)));
    this.deny = [...HOME_DENY.map(d => path.join(this.home, d)), ...SYSTEM_DENY, ...extraDeny.map(d => realish(expandHome(d, home)))];
  }

  /** `deny`: never. `root`: inside an allowed folder. `outside`: exists somewhere else; every access needs a fresh approval. */
  check(target, { cwd = this.home } = {}) {
    const abs = path.resolve(expandHome(cwd, this.home), expandHome(target, this.home)), real = realish(abs);
    for (const candidate of new Set([abs, real])) {
      for (const d of this.deny) if (inside(candidate, d)) return { verdict: 'deny', path: real, reason: 'protected location (credentials, keys, browser data or system files)' };
      const base = path.basename(candidate);
      if (!NAME_ALLOW.some(r => r.test(base)) && NAME_DENY.some(r => r.test(base))) return { verdict: 'deny', path: real, reason: 'looks like a credential or key file' };
    }
    const root = this.roots.find(r => inside(real, r));
    return { verdict: root ? 'root' : 'outside', path: real, root };
  }

  /** A workspace is a folder inside the roots that is not a root itself or the home folder: the only place automatic edits may happen. */
  workspace(cwd) {
    const c = this.check(cwd);
    if (c.verdict !== 'root' || c.path === this.home || this.roots.includes(c.path)) return null;
    return c.path;
  }
}

// ---- commands ----

const READ_ONLY_COMMANDS = new Set(['ls', 'pwd', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'find', 'file', 'stat', 'du', 'df', 'date', 'whoami', 'uname', 'sw_vers', 'which', 'echo', 'tree', 'basename', 'dirname', 'sort', 'uniq', 'cut', 'diff', 'uptime',
  'mdfind', 'mdls', 'strings', 'vm_stat', 'memory_pressure', 'system_profiler', 'hostname', 'id']);
// `ps` may list processes but never their arguments or environment (command lines carry tokens); only these columns.
const PS_FIELDS = new Set(['pid', 'ppid', 'user', '%cpu', '%mem', 'rss', 'vsz', 'etime', 'state', 'stat', 'comm', 'lstart', 'time', 'nice', 'pri']);
const READ_ONLY_GIT = new Set(['status', 'diff', 'log', 'show', 'branch', 'rev-parse', 'ls-files', 'remote', 'describe', 'blame', 'shortlog', 'tag', 'config']);
const SHELL_META = /[;&|<>`$()\\\n{}]/;
const NETWORK_COMMANDS = /(^|[\s;&|(`'"/])(curl|wget|ssh|scp|sftp|rsync|nc|ncat|telnet|ftp|ping|dig|nslookup|brew|pip3?|pipx|npm|npx|pnpm|yarn|bun|gem|cargo|go|docker|kubectl|gh)(\s|$)|\bgit\s+(push|pull|fetch|clone|remote\s+add|submodule)\b/;
const DESTRUCTIVE = /(^|\s)(rm|rmdir|dd|mkfs\S*|diskutil|chown|chmod\s+-R|kill|killall|pkill|launchctl|defaults\s+(write|delete)|networksetup|pmset|csrutil|tmutil|shutdown|reboot|halt|srm|trash|osascript|security)\b|git\s+(reset\s+--hard|clean|push\s+(-f|--force)|checkout\s+--|restore)/;

/**
 * Splits a shell line into simple commands joined by `;` `&&` `||` `|` or newlines, understanding quotes. Returns null for anything that could
 * run something else or write somewhere: command substitution, variables, subshells, redirects (except discarding to /dev/null), background jobs.
 */
export function splitSimpleCommands(text) {
  const segments = [[]]; let word = '', inWord = false, quote = null;
  const endWord = () => { if (inWord) { segments.at(-1).push(word); word = ''; inWord = false; } };
  const cut = () => { endWord(); if (segments.at(-1).length) segments.push([]); };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote === "'") { if (c === "'") quote = null; else word += c; continue; }
    if (quote === '"') { if (c === '"') quote = null; else if (c === '$' || c === '`' || c === '\\') return null; else word += c; continue; }
    if (c === "'" || c === '"') { quote = c; inWord = true; continue; }
    if (c === ' ' || c === '\t') { endWord(); continue; }
    if (c === '\n' || c === ';') { cut(); continue; }
    if (c === '|') { cut(); if (text[i + 1] === '|') i++; continue; }
    if (c === '&') { if (text[i + 1] === '&') { cut(); i++; continue; } if (/\d/.test(word) && inWord && text[i - 1] === '>') { word += c; continue; } return null; }
    if (c === '>' && /^\d?$/.test(word)) {                       // only "N>/dev/null" and "N>&M" are accepted
      const rest = text.slice(i);
      const m = rest.match(/^>\s*\/dev\/null(?![\w/.])/) ?? rest.match(/^>&\d(?!\w)/);
      if (!m) return null;
      word = ''; inWord = false; i += m[0].length - 1; continue;
    }
    if ('`$()<>{}\\'.includes(c)) return null;
    word += c; inWord = true;
  }
  if (quote) return null;
  endWord();
  return segments.filter(seg => seg.length);
}

function psArgumentsAllowed(args) {
  for (let i = 0; i < args.length; i++) {
    const w = args[i];
    if (/^-[A-DF-Za-df-z]*o$/.test(w)) {                       // an option cluster ending in o takes the column list
      const list = args[++i];
      if (!list || !list.split(',').every(f => PS_FIELDS.has(f.split('=')[0]))) return false;
    } else if (!/^-[A-DF-Za-df-z]+$/.test(w)) return false;    // plain options only: no e/E (environment), no BSD-style words
  }
  return true;
}

const readOnlyWords = (words) => {
  const head = words[0]?.split('/').pop();
  if (READ_ONLY_COMMANDS.has(head)) {
    if (head === 'find' && words.some(w => /^-(exec|execdir|ok|okdir|delete|fprint\S*|fls)$/.test(w))) return null;
    if (head === 'sort' && words.some(w => /^(-o|--output)/.test(w))) return null;
    if (head === 'rg' && words.some(w => /^--(pre|pre-glob|hostname-bin|no-config)/.test(w))) return null;         // --pre and --hostname-bin run programs
    return { paths: words.slice(1).filter(w => !w.startsWith('-')) };
  }
  if (head === 'scutil' && words[1] === '--get' && words.length === 3) return { paths: [] };
  if (head === 'pmset' && words[1] === '-g' && words.slice(2).every(w => /^[a-z]+$/.test(w))) return { paths: [] };
  if (head === 'ps' && psArgumentsAllowed(words.slice(1))) return { paths: [] };
  if (head === 'textutil' && words.includes('-stdout') && words.includes('-convert')) return { paths: words.slice(1).filter(w => !w.startsWith('-') && !['txt', 'html', 'rtf'].includes(w)) };
  if (head === 'pdftotext' && words.at(-1) === '-' && !words.slice(1).some(w => /^-(upw|opw)$/.test(w))) return { paths: words.slice(1, -1).filter(w => !w.startsWith('-')) };
  if (head === 'defaults' && words[1] === 'read') return { paths: [] };
  if (head === 'git' && READ_ONLY_GIT.has(words[1]) && !words.some(w => /^(--output|-o|--ext-diff|--textconv|-c|-C)/.test(w))
      && !(words[1] === 'config' && !words.includes('--get')) && !(words[1] === 'branch' && words.some(w => /^-(d|D|m|M|c|C|-delete|-move|-copy)$/.test(w)))
      && !(words[1] === 'tag' && words.some(w => /^-(d|a|s|m|f)$/.test(w) || w === '--delete'))
      && !(words[1] === 'remote' && !(words.length === 2 || (words[2] === '-v' && words.length === 3)))) return { paths: [] };
  return null;
};

export function classifyCommand(command) {
  const text = String(command ?? '').trim();
  if (!text || text.length > 4000) return { kind: 'deny', risk: 'sensitive', reason: 'empty or too long' };
  if (/(^|[\s;&|(])(sudo|su|doas)(\s|$)/.test(text)) return { kind: 'deny', risk: 'sensitive', reason: 'administrator commands are not available to the phone' };
  if (/\b(curl|wget)\b.*\|\s*(sh|bash|zsh)\b/.test(text)) return { kind: 'deny', risk: 'sensitive', reason: 'piping downloads into a shell is not allowed' };
  const segments = splitSimpleCommands(text);
  if (segments?.length) {
    const checked = segments.map(readOnlyWords);
    if (checked.every(Boolean)) return { kind: 'read', risk: 'read', paths: checked.flatMap(c => c.paths) };
  }
  if (DESTRUCTIVE.test(text)) return { kind: 'ask', risk: 'sensitive', reason: 'can delete or overwrite data, or change the system' };
  if (NETWORK_COMMANDS.test(text)) return { kind: 'ask', risk: 'external', reason: 'uses the network or sends data off this computer', network: true };
  return { kind: 'ask', risk: 'modify', reason: 'runs a program that may change files' };
}

export const SCOPES_BY_RISK = { read: ['once', 'task'], modify: ['once', 'task'], external: ['once'], sensitive: ['once'] };

/** Seatbelt profile: no network, writes only in the workspace and temp folders, protected locations unreadable. */
export function sandboxProfile({ workspace = null, policy }) {
  const q = (s) => JSON.stringify(s);
  const lines = ['(version 1)', '(allow default)', '(deny network*)', '(deny file-write*)',
    `(allow file-write* ${[workspace, '/private/tmp', '/private/var/folders'].filter(Boolean).map(p => `(subpath ${q(p)})`).join(' ')} (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))`];
  for (const d of policy.deny) lines.push(`(deny file-read* (subpath ${q(d)}))`);
  return lines.join('\n');
}

/** True when `sandbox-exec` works here (checked once at start). Without it nothing runs automatically: every command asks. */
export function sandboxSupported() {
  try { execFileSync('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)', '/usr/bin/true'], { stdio: 'ignore', timeout: 5000 }); return true; } catch { return false; }
}
