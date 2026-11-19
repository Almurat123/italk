#!/usr/bin/env node
// End-to-end check with the REAL pieces: an iTalk gateway (real model provider behind it), a real Mac agent process logic, a paired phone (Node
// implementation of the phone protocol), real tools on this Mac. Costs a few cents of model usage. Not part of `npm test`.
//
//   ITALK_E2E_GATEWAY=http://127.0.0.1:8796 ITALK_E2E_DB=/tmp/e2e/gw.sqlite node tools/e2e.mjs [scenario …]
//
// Scenarios: read, skill, write, plan, web, resume, cancel   (default: all). Writes a JSON report next to the docs/measurements.
import { mkdirSync, writeFileSync, readFileSync, existsSync, mkdtempSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startPaired, memoryKeychain, sleep, scratch } from '../test/helpers.mjs';

const gateway = process.env.ITALK_E2E_GATEWAY ?? 'http://127.0.0.1:8796';
const dbPath = process.env.ITALK_E2E_DB ?? '/tmp/e2e/gw.sqlite';
const here = path.dirname(fileURLToPath(import.meta.url));
const wanted = process.argv.slice(2);
const realSleep = (ms, signal) => new Promise((resolve, reject) => { const t = setTimeout(resolve, ms); signal?.addEventListener('abort', () => { clearTimeout(t); reject(Object.assign(new Error('aborted'), { name: 'AbortError' })); }, { once: true }); });
const report = { date: new Date().toISOString(), gateway: gateway.replace(/^(https?:\/\/[^/]+).*/, '$1'), host: execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim(), scenarios: [] };

async function api(method, p, { token, body } = {}) {
  const r = await fetch(gateway + p, { method, headers: { ...(body ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text(); return { status: r.status, json: text ? JSON.parse(text) : null };
}

// 1. An account with a subscription, and a credential for the computer minted from it (what the phone does after pairing).
const email = `e2e-${Date.now()}@example.com`;
const reg = await api('POST', '/v2/auth/register', { body: { email, password: 'e2e-password-123', displayName: 'E2E' } });
if (reg.status !== 201) throw new Error(`register failed ${reg.status} ${JSON.stringify(reg.json)}`);
execFileSync('node', [path.join(here, '../../../server/tools/dev-grant.mjs'), dbPath, email], { stdio: 'pipe' });
const minted = await api('POST', '/v2/agent-sessions', { token: reg.json.session.token, body: { name: 'E2E Mac' } });
const credential = minted.json.session;
console.log(`account ${email}; computer credential issued (${credential.name})`);

// 2. A Mac with real files.
const sc = scratch('e2e-');
const home = path.join(sc.dir, 'home'); const downloads = path.join(home, 'Downloads'), work = path.join(home, 'work');
mkdirSync(downloads, { recursive: true }); mkdirSync(work, { recursive: true });
for (const [name, kb] of [['holiday-video.mov', 5200], ['report-2026.pdf', 830], ['archive.zip', 2400], ['notes.txt', 3], ['photo-001.jpg', 1900], ['setup.dmg', 4100]]) writeFileSync(path.join(downloads, name), Buffer.alloc(kb * 1024, 65));
writeFileSync(path.join(work, 'AGENTS.md'), 'Answer in Chinese. Keep answers under five sentences.');
const keychain = memoryKeychain();
let ctx = await startPaired({ sleep: realSleep, scratchDir: sc.dir, keychain, home, config: { maxPermissionMode: 'acceptEdits', approvalTimeoutMinutes: 5 } });
const put = await ctx.phone.call('PUT', '/v1/cloud', { gateway, token: credential.token, accountHint: 'e***@example.com', sessionName: credential.name });
console.log('hand-over:', put.status, JSON.stringify({ ok: put.json?.verification?.ok, models: put.json?.verification?.models?.map(m => m.id), plan: put.json?.verification?.subscription?.planName ?? put.json?.verification?.subscription?.status }));
if (!put.json?.verification?.ok) throw new Error('the gateway did not accept the computer: ' + JSON.stringify(put.json));

const submit = (body, key = `e2e-${Math.random().toString(36).slice(2, 12)}-k`) => ctx.phone.call('POST', '/v1/tasks', { backend: 'italk', ...body }, { headers: { 'idempotency-key': key } });
async function run(name, body, { answers = {}, approve = true, timeoutMs = 150_000, after } = {}) {
  const started = Date.now(); const t = await submit(body);
  if (t.status >= 300) { report.scenarios.push({ name, ok: false, error: t.json }); console.log(`✗ ${name}: ${JSON.stringify(t.json)}`); return null; }
  const id = t.json.task.id; let seq = 0, events = [], done = null;
  const approvals = [], questions = [];
  while (Date.now() - started < timeoutMs && !done) {
    const r = (await ctx.phone.call('GET', `/v1/tasks/${id}/events?after=${seq}`)).json;
    for (const e of r.events) {
      events.push(e); seq = e.seq;
      if (e.type === 'approval_requested') { approvals.push(e.data.summary); const yes = approve && e.data.tool !== 'open_url'; /* never open things on the owner's screen from a test */ await ctx.phone.call('POST', `/v1/approvals/${e.data.approvalId}`, { decision: yes ? 'approve' : 'decline', scope: 'once' }); }
      if (e.type === 'question_requested') { questions.push(e.data.question); await ctx.phone.call('POST', `/v1/questions/${e.data.questionId}`, { answer: answers[e.data.question] ?? e.data.choices?.[0] ?? '继续' }); }
      if (['completed', 'failed', 'cancelled'].includes(e.type)) done = e;
    }
    if (after && !done && await after({ id, events })) return { id, events, partial: true };
    if (!done) await sleep(400);
  }
  const text = events.filter(e => e.type === 'text').map(e => e.data.text).join('');
  const tools = events.filter(e => e.type === 'tool_call').map(e => e.data.name);
  const usage = events.filter(e => e.type === 'usage').reduce((a, e) => ({ input: a.input + (e.data.inputTokens ?? 0), output: a.output + (e.data.outputTokens ?? 0) }), { input: 0, output: 0 });
  const result = { name, ok: done?.type === 'completed', state: done?.type ?? 'timeout', seconds: Math.round((Date.now() - started) / 100) / 10, tools, approvals, questions, steps: events.filter(e => e.type === 'usage').length, usage, plan: events.filter(e => e.type === 'plan').at(-1)?.data.items ?? null, answer: text.slice(0, 700), error: done?.type === 'failed' ? done.data : undefined };
  report.scenarios.push(result);
  console.log(`${result.ok ? '✓' : '✗'} ${name} — ${result.state} in ${result.seconds}s, tools: ${tools.join(', ') || '-'}${approvals.length ? `, approvals: ${approvals.length}` : ''}\n   ${text.replace(/\s+/g, ' ').slice(0, 260)}`);
  return { id, events, result };
}
const use = (n) => wanted.length === 0 || wanted.includes(n);

if (use('read')) {
  const r = await run('read: biggest files in Downloads', { prompt: '看看我的下载文件夹里最大的 3 个文件，告诉我名字和大小。不要改动任何东西。', cwd: downloads, permissionMode: 'readOnly' });
  const last = report.scenarios.at(-1);
  last.checked = { mentionsLargest: /holiday-video/.test(last.answer), mentionsSecond: /setup\.dmg/.test(last.answer) };
  last.ok = last.ok && Object.values(last.checked).every(Boolean);
}
if (use('skill')) {
  await run('skill: Mac health check', { prompt: '检查一下这台 Mac 现在的状态：电池、磁盘空间、内存，有没有问题？', cwd: work, permissionMode: 'ask' }, { approve: true });
  const last = report.scenarios.at(-1); last.checked = { loadedSkill: last.tools.includes('skill_view') }; last.ok = last.ok && Object.values(last.checked).every(Boolean);
}
if (use('write')) {
  const r = await run('write: create a file after approval', { prompt: '在工作文件夹里创建 hello.md，内容是一句问候和今天的日期（用 date 命令得到），然后告诉我文件内容。', cwd: work, permissionMode: 'ask' }, { approve: true });
  const last = report.scenarios.at(-1); last.checked = { fileExists: existsSync(path.join(work, 'hello.md')), approvalAsked: last.approvals.length > 0 }; last.ok = last.ok && Object.values(last.checked).every(Boolean);
}
if (use('plan')) {
  await run('plan: multi-step with a plan', { prompt: '先统计下载文件夹里每种扩展名各有几个文件，再按文件大小从大到小列出前两个。用 todo 工具写下计划。', cwd: downloads, permissionMode: 'readOnly' });
  const last = report.scenarios.at(-1); last.checked = { hasPlan: Array.isArray(last.plan) && last.plan.length > 0 }; last.ok = last.ok && Object.values(last.checked).every(Boolean);
}
if (use('web')) {
  await run('web: fetch a public page', { prompt: '打开 https://example.com 这个网页，告诉我页面的标题和第一段的大意。', cwd: work, permissionMode: 'acceptEdits' });
  const last = report.scenarios.at(-1); last.checked = { fetched: last.tools.includes('web_fetch') }; last.ok = last.ok && Object.values(last.checked).every(Boolean);
}
if (use('cancel')) {
  const t = await submit({ prompt: '请一个一个地读取下载文件夹里的每个文件的前 200 字节，逐个汇报，不要省略。', cwd: downloads, permissionMode: 'readOnly' });
  await sleep(2500); await ctx.phone.call('POST', `/v1/tasks/${t.json.task.id}/cancel`, {});
  let state; for (let i = 0; i < 30; i++) { state = (await ctx.phone.call('GET', `/v1/tasks/${t.json.task.id}`)).json.task.state; if (state === 'cancelled') break; await sleep(300); }
  report.scenarios.push({ name: 'cancel: stops the task', ok: state === 'cancelled', state }); console.log(`${state === 'cancelled' ? '✓' : '✗'} cancel — ${state}`);
}
if (use('resume')) {
  // The Mac's program restarts while the model is working; the task continues from its saved state.
  const phone = ctx.phone;
  const t = await submit({ prompt: '用工具依次查看下载文件夹里每个文件的大小（stat），然后告诉我总共多少 MB。', cwd: downloads, permissionMode: 'readOnly' });
  const id = t.json.task.id;
  for (let i = 0; i < 100; i++) { const r = (await phone.call('GET', `/v1/tasks/${id}/events?after=0`)).json; if (r.events.some(e => e.type === 'tool_result')) break; await sleep(200); }
  await ctx.agent.close();
  console.log('   … the agent restarted mid-task');
  ctx = await startPaired({ sleep: realSleep, scratchDir: sc.dir, keychain, home, stateDir: path.join(sc.dir, 's'), phone, config: { maxPermissionMode: 'acceptEdits', approvalTimeoutMinutes: 5 } });
  let events = [], seq = 0, end;
  for (let i = 0; i < 400 && !end; i++) { const r = (await ctx.phone.call('GET', `/v1/tasks/${id}/events?after=${seq}`)).json; for (const e of r?.events ?? []) { events.push(e); seq = e.seq; if (['completed', 'failed', 'cancelled'].includes(e.type)) end = e; } if (!end) await sleep(400); }
  const text = events.filter(e => e.type === 'text').map(e => e.data.text).join('');
  const out = { name: 'resume: continues after the agent restarts', ok: end?.type === 'completed' && events.some(e => e.type === 'status' && /restarted/.test(e.data.message)), state: end?.type ?? 'timeout', resumedNote: events.some(e => e.type === 'status' && /restarted/.test(e.data.message)), answer: text.slice(0, 400) };
  report.scenarios.push(out); console.log(`${out.ok && out.resumedNote ? '✓' : '✗'} resume — ${out.state}, noted: ${out.resumedNote}\n   ${text.replace(/\s+/g, ' ').slice(0, 220)}`);
}

await ctx.stop();
const outFile = path.join(here, '../../../docs/measurements', `${new Date().toISOString().slice(0, 10)}-mac-agent-e2e.json`);
writeFileSync(outFile, JSON.stringify(report, null, 2) + '\n');
console.log(`\nreport: ${path.relative(process.cwd(), outFile)}; ${report.scenarios.filter(s => s.ok).length}/${report.scenarios.length} scenarios ok`);
process.exit(report.scenarios.every(s => s.ok) ? 0 : 1);
