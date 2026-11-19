import { createInterface } from 'node:readline/promises';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import qrcode from 'qrcode-terminal';
import { createAgent, AGENT_VERSION } from './server.mjs';
import { loadConfig, saveConfig, stateDirDefault, DEFAULT_PORT, logDirDefault } from './config.mjs';
import { controlRequest, controlSession } from './control-client.mjs';
import { installService, uninstallService, serviceLoaded, plistPath } from './service.mjs';
import { MODES } from './policy.mjs';

const USAGE = `iTalk agent — lets your iPhone work on this Mac using iTalk cloud models or local Ollama models.

  italk-agent setup                    first time: start the background service, then show the QR code to pair your iPhone
  italk-agent pair                     show a QR code to pair another iPhone (the service must be running)
  italk-agent status | devices | tasks | approvals | cloud | skills
  italk-agent approve <id> | decline <id>        answer an approval from this computer
  italk-agent revoke <deviceId>        remove a paired iPhone
  italk-agent set mode <readOnly|ask|acceptEdits|auto>   highest permission mode a phone may choose (default ask)
  italk-agent set name <name> | port <n> | public-url <url> | root <dir> | remove-root <dir>
  italk-agent install-service | uninstall-service | logs
  italk-agent run                      run in the foreground (what the service does)
  italk-agent doctor
Options: --state-dir <dir>

Managed cloud model access comes from your iTalk account. Local Ollama models are discovered at 127.0.0.1:11434 and do not need an iTalk account.`;

const flags = (argv) => {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['no-bonjour', 'insecure-auto-approve-pairing', 'json'].includes(k)) out[k] = true;
      else out[k] = argv[++i];
    } else out._.push(a);
  }
  return out;
};

const log = (event, fields = {}) => console.log(JSON.stringify({ t: new Date().toISOString(), event, ...fields }));
const table = (rows) => rows.map(r => '  ' + r.join('  ')).join('\n');
const ago = (t) => (t ? new Date(t).toLocaleString() : '—');

export async function main(argv, { stdout = console.log } = {}) {
  const f = flags(argv), cmd = f._[0];
  const stateDir = f['state-dir'] ?? process.env.ITALK_AGENT_STATE ?? stateDirDefault();
  const say = stdout;
  const request = async (msg) => {
    try { return await controlRequest(stateDir, msg); }
    catch (error) { if (error.code === 'not_running') { say(`${error.message}\nStart it with:  italk-agent setup   (or  italk-agent run  in a terminal)`); process.exitCode = 3; return null; } throw error; }
  };

  switch (cmd) {
    case 'run': return run({ stateDir, f });
    case 'setup': return setup({ stateDir, say });
    case 'pair': return pair({ stateDir, say });
    case 'status': {
      const r = await request({ op: 'status' }); if (!r) return;
      if (f.json) return say(JSON.stringify(r, null, 2));
      const b = r.backends.find(x => x.id === 'italk');
      say(`${r.agent.name}  (id ${r.agent.id}, v${r.agent.version})\nfingerprint ${r.agent.fingerprint}\nlistening on port ${r.port}; ${r.devices} paired phone(s); ${r.tasksRunning} task(s) running\nmodel access: ${b?.available ? `ready (${b.models.join(', ')})` : b?.detail ? `not ready: ${b.detail}` : 'not set up'}\nreachable at:\n${r.endpoints.map(e => '  ' + e).join('\n')}`);
      return;
    }
    case 'cloud': {
      const r = await request({ op: 'cloud', verify: true }); if (!r) return;
      if (f.json) return say(JSON.stringify(r, null, 2));
      if (!r.cloud.configured) return say('No model access yet. Pair an iPhone (italk-agent pair); it sends this computer a credential for your iTalk account.');
      const v = r.verification;
      say(`Gateway  ${r.cloud.gateway}\nAccount  ${r.cloud.accountHint ?? '—'}   credential issued ${ago(r.cloud.issuedAt)}\nStatus   ${v.ok ? 'ready' : `not ready (${v.code}): ${v.message}`}${v.models?.length ? `\nModels   ${v.models.map(m => m.id).join(', ')}` : ''}${v.subscription ? `\nPlan     ${v.subscription.planName ?? v.subscription.status}` : ''}`);
      return;
    }
    case 'skills': {
      const r = await request({ op: 'skills' }); if (!r) return;
      say(r.skills.length ? table(r.skills.map(s => [s.name.padEnd(28), s.source.padEnd(9), s.description.slice(0, 70)])) : 'No skills found.');
      say(`\nPut your own in: ${r.userDir}/<name>/SKILL.md   (or <project>/.italk/skills/<name>/SKILL.md)`);
      return;
    }
    case 'devices': { const r = await request({ op: 'devices' }); if (!r) return; say(r.devices.length ? table(r.devices.map(d => [d.revokedAt ? '✕' : '●', d.id, d.name.padEnd(20), `paired ${ago(d.pairedAt)}`, `last seen ${ago(d.lastSeen)}`])) : 'No phone is paired. Run:  italk-agent pair'); return; }
    case 'revoke': { const r = await request({ op: 'revoke', id: f._[1] }); if (r) say(r.type === 'ok' ? 'Removed. That phone can no longer reach this computer.' : `Failed: ${r.code}`); return; }
    case 'tasks': { const r = await request({ op: 'tasks' }); if (!r) return; say(r.tasks.length ? table(r.tasks.map(t => [t.state.padEnd(9), ago(t.createdAt), (t.title ?? '').slice(0, 50), t.id])) : 'No tasks yet.'); return; }
    case 'approvals': { const r = await request({ op: 'approvals' }); if (!r) return; say(r.approvals.length ? r.approvals.map(a => `${a.id}  [${a.risk}] ${a.summary}`).join('\n') + '\n\nAnswer with:  italk-agent approve <id>  |  italk-agent decline <id>' : 'Nothing is waiting for an answer.'); return; }
    case 'approve': case 'decline': { const r = await request({ op: 'resolve', id: f._[1], decision: cmd }); if (r) say(r.type === 'ok' ? `${cmd}d.` : `Failed: ${r.code}`); return; }
    case 'set': return setCommand({ stateDir, f, say });
    case 'install-service': {
      const cfg = loadConfig(stateDir); saveConfig(stateDir, cfg);
      const out = installService({ stateDir });
      say(`Installed. The agent now runs in the background and starts at login.\n  service  ${out.plist}\n  logs     ${out.logFile}\nNext: italk-agent pair`);
      return;
    }
    case 'uninstall-service': uninstallService(); say('Stopped and removed the background service. Your pairings and history stay in ' + stateDir); return;
    case 'logs': { const file = path.join(logDirDefault(), 'agent.log'); spawn('tail', ['-n', '80', '-f', file], { stdio: 'inherit' }); return; }
    case 'doctor': return doctor({ stateDir, say });
    case 'version': say(AGENT_VERSION); return;
    default: say(USAGE); if (cmd && cmd !== 'help') process.exitCode = 2;
  }
}

async function run({ stateDir, f }) {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const config = loadConfig(stateDir);
  if (f.port) config.port = Number(f.port);
  const auto = Boolean(f['insecure-auto-approve-pairing']) && process.env.ITALK_AGENT_INSECURE_TEST === '1';
  const agent = await createAgent({ stateDir, config, log, autoApprovePairing: auto, dnssd: !f['no-bonjour'] });
  const port = await agent.listen({ port: config.port });
  log('listening', { port, agent: agent.identity.deviceId, name: config.name, backends: [...agent.backends.keys()], maxPermissionMode: config.maxPermissionMode });
  if (f.json) {
    // Test harness only (needs ITALK_AGENT_INSECURE_TEST=1): open one pairing immediately and print its link, auto-approved.
    let pairingLink;
    if (auto) { agent.pairing.endpoints = [`https://127.0.0.1:${port}`]; pairingLink = agent.pairing.begin().uri; }
    console.log(JSON.stringify({ ready: true, port, stateDir, agentId: agent.identity.deviceId, ...(pairingLink ? { pairingLink } : {}) }));
  }
  const stop = async (signal) => { log('stopping', { signal }); await agent.close().catch(() => {}); process.exit(0); };
  process.on('SIGTERM', () => stop('SIGTERM')); process.on('SIGINT', () => stop('SIGINT'));
  process.on('uncaughtException', (error) => { log('fatal', { message: String(error?.message ?? error) }); process.exit(1); });
  process.on('unhandledRejection', (error) => { log('unhandled_rejection', { message: String(error?.message ?? error) }); });
}

/** First time on a Mac: background service up, then the QR code. Safe to run again. */
async function setup({ stateDir, say }) {
  const nodeMajor = Number(process.versions.node.split('.')[0]);
  if (nodeMajor < 22) { say(`This needs Node 22.13 or newer (found ${process.versions.node}). Install it from https://nodejs.org and run setup again.`); process.exitCode = 1; return; }
  say('1/3  Starting the iTalk agent in the background…');
  const cfg = loadConfig(stateDir); saveConfig(stateDir, cfg);
  let ready = await controlRequest(stateDir, { op: 'status' }).catch(() => null);
  if (!ready) {
    installService({ stateDir });
    for (let i = 0; i < 40 && !ready; i++) { await new Promise(r => setTimeout(r, 500)); ready = await controlRequest(stateDir, { op: 'status' }).catch(() => null); }
  }
  if (!ready) { say('The background service did not start. Run  italk-agent doctor  and  italk-agent logs  to see why.'); process.exitCode = 3; return; }
  say(`     running as "${ready.agent.name}" (port ${ready.port}).`);
  say('2/3  Pairing your iPhone: open iTalk → 设置 → 我的电脑 → 扫码添加.');
  await pair({ stateDir, say });
  if (process.exitCode) return;
  say('3/3  The iPhone now sends this computer its model access. Check it with:  italk-agent cloud');
  const r = await controlRequest(stateDir, { op: 'cloud', verify: true }).catch(() => null);
  if (r?.verification?.ok) say(`     ready: ${r.verification.models.map(m => m.id).join(', ')}`);
  else say('     waiting for the iPhone (keep the iTalk app open for a moment).');
}

async function pair({ stateDir, say }) {
  let session;
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const done = new Promise((resolve) => {
    controlSession(stateDir, async (m) => {
      if (m.type === 'qr') {
        say('\nScan this code with iTalk on your iPhone  (设置 → 我的电脑 → 扫码添加)\n');
        qrcode.generate(m.uri, { small: true }, (code) => say(code));
        say(`This computer's code: ${m.agentFingerprint}\nThe code is valid for 5 minutes. Reachable at:\n${m.endpoints.map(e => '  ' + e).join('\n')}\n\nOr paste this link into iTalk:\n${m.uri}\n`);
        say('Waiting for the phone…');
      } else if (m.type === 'confirm') {
        say(`\nA phone wants to pair:\n  name         ${m.phoneName}\n  its code     ${m.fingerprint}\n(the same code is shown on the iPhone)`);
        const answer = (await rl.question('Allow this phone to use this computer? [y/N] ')).trim().toLowerCase();
        session.send({ op: 'answer', approve: answer === 'y' || answer === 'yes' });
      } else if (m.type === 'paired') { say('\n✓ Paired. You can now send tasks to this computer from iTalk.'); resolve(0); }
      else if (m.type === 'expired') { say('\nThe code expired. Run  italk-agent pair  again.'); resolve(1); }
      else if (m.type === 'error') { say(`\nCannot pair: ${m.code}${m.code === 'pairing_in_progress' ? ' (another  italk-agent pair  is already waiting)' : ''}`); resolve(1); }
    }, () => resolve(process.exitCode ?? 0)).then((s) => { session = s; s.send({ op: 'pair' }); }).catch((error) => { say(`${error.message}\nStart it with:  italk-agent setup`); resolve(3); });
  });
  const code = await done; rl.close(); session?.close(); process.exitCode = code;
}

function setCommand({ stateDir, f, say }) {
  const [, key, value] = f._;
  const cfg = loadConfig(stateDir);
  switch (key) {
    case 'mode': if (!MODES.includes(value)) return say(`Mode must be one of ${MODES.join(', ')}.`); cfg.maxPermissionMode = value; break;
    case 'name': cfg.name = value; break;
    case 'port': cfg.port = Number(value) || DEFAULT_PORT; break;
    case 'public-url': if (!/^https:\/\//.test(value ?? '')) return say('The URL must start with https://'); cfg.publicUrls = [...new Set([...cfg.publicUrls, value])]; break;
    case 'root': cfg.roots = [...new Set([...cfg.roots, value])]; break;
    case 'remove-root': cfg.roots = cfg.roots.filter(r => r !== value); break;
    default: return say('Unknown setting. See: italk-agent help');
  }
  saveConfig(stateDir, cfg);
  say(`Saved. Restart the service to apply:  italk-agent install-service`);
}

async function doctor({ stateDir, say }) {
  const lines = [];
  const ok = (good, text) => lines.push(`${good ? '✓' : '✗'} ${text}`);
  ok(Number(process.versions.node.split('.')[0]) >= 22, `Node ${process.versions.node} (22.13 or newer needed for the built-in database)`);
  ok(existsSync('/usr/bin/sandbox-exec'), 'sandbox-exec present (used to confine automatic commands)');
  ok(existsSync(plistPath()), `launch agent installed (${plistPath()})`);
  ok(serviceLoaded(), 'launch agent loaded');
  const r = await controlRequest(stateDir, { op: 'status' }).catch(() => null);
  ok(Boolean(r), r ? `agent answering on port ${r.port}` : 'agent not answering');
  if (r) {
    ok(r.devices > 0, `${r.devices} paired phone(s)`);
    const b = r.backends.find(x => x.id === 'italk');
    ok(Boolean(b?.available), `model access through iTalk: ${b?.available ? 'ready' : b?.detail ?? 'not set up (pair an iPhone)'}`);
  }
  // A leftover from versions that kept a model key on the Mac. Nothing reads it any more; the person decides whether to delete it.
  try {
    execFileSync('security', ['find-generic-password', '-s', 'iTalk Agent', '-a', 'deepseek'], { stdio: 'ignore', timeout: 5000 });
    lines.push("! An old model key from an earlier version is still in your login Keychain (\"iTalk Agent\" / deepseek). Nothing uses it any more. Remove it with:  security delete-generic-password -s 'iTalk Agent' -a deepseek");
  } catch {}
  say(lines.join('\n'));
}
