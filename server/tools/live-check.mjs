// End-to-end check of a running gateway v2 against the real provider:
//   node tools/live-check.mjs http://127.0.0.1:8795 <db path>      (dev only: grants itself a subscription through the local database file)
import { execFileSync } from 'node:child_process';
const [base = 'http://127.0.0.1:8795', db = './data/italk-dev.sqlite'] = process.argv.slice(2);
const email = `live-${Date.now()}@example.com`;
const j = async (method, path, { token, body, headers } = {}) => {
  const r = await fetch(base + path, { method, headers: { ...(body ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text(); return { status: r.status, json: text ? JSON.parse(text) : null };
};
async function sse(token, id, after = 0, max = Infinity) {
  const r = await fetch(`${base}/v2/tasks/${id}/stream`, { headers: { authorization: `Bearer ${token}`, 'last-event-id': String(after) } });
  const reader = r.body.getReader(), dec = new TextDecoder(); let buf = '', out = [];
  while (out.length < max) {
    const { done, value } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    let i; while ((i = buf.indexOf('\n\n')) >= 0) {
      const block = buf.slice(0, i); buf = buf.slice(i + 2);
      const id = /^id: (\d+)$/m.exec(block), type = /^event: (.+)$/m.exec(block), data = /^data: (.+)$/m.exec(block);
      if (id && type) out.push({ seq: +id[1], type: type[1], data: JSON.parse(data[1]) });
    }
  }
  await reader.cancel().catch(() => {}); return out;
}
const reg = await j('POST', '/v2/auth/register', { body: { email, password: 'live-check-password', displayName: '联调' } });
console.log('register', reg.status);
const token = reg.json.session.token;
execFileSync('node', ['tools/dev-grant.mjs', db, email], { stdio: 'inherit' });
const tools = [{ name: 'weather_forecast', description: '查询某地天气', parameters: { type: 'object', properties: { place: { type: 'string' } }, required: ['place'] } }];
const t0 = Date.now();
const created = await j('POST', '/v2/tasks', { token, headers: { 'idempotency-key': `live-${email}-1` }, body: { model: 'deepseek-flash', reasoningEffort: 'low', maxTokens: 400, tools,
  messages: [{ role: 'system', text: '你是助手。需要天气时调用工具。' }, { role: 'user', text: '杭州今天天气怎么样？' }] } });
console.log('create', created.status, created.json.task?.state ?? created.json);
const id = created.json.task.id;
const first = await sse(token, id, 0, 3);                          // read a few events, then drop the connection
console.log('first reader got', first.map(e => `${e.seq}:${e.type}`).join(' '));
const rest = await sse(token, id, first.at(-1).seq);                // reconnect with the cursor
console.log('second reader got', rest.map(e => `${e.seq}:${e.type}`).join(' '), `(${Date.now() - t0} ms)`);
const all = [...first, ...rest];
console.log('gapless:', all.every((e, i) => e.seq === i + 1));
const call = all.find(e => e.type === 'tool_call');
const usage = all.find(e => e.type === 'usage');
console.log('reasoning chars:', all.filter(e => e.type === 'reasoning').reduce((n, e) => n + e.data.text.length, 0), '| tool call:', call?.data.name, call?.data.arguments, '| usage:', JSON.stringify(usage?.data));
// second step: history produced by ANOTHER model (no reasoning content) plus a tool result, thinking on
const step2 = await j('POST', '/v2/tasks', { token, headers: { 'idempotency-key': `live-${email}-2` }, body: { model: 'deepseek-flash', reasoningEffort: 'low', maxTokens: 400, tools,
  messages: [{ role: 'user', text: '杭州今天天气怎么样？' }, { role: 'assistant', text: '', toolCalls: [{ id: 'c1', name: 'weather_forecast', arguments: '{"place":"杭州"}' }] },
             { role: 'tool', text: '{"weather":"晴","temperature":18}', toolCallId: 'c1' }] } });
const events2 = await sse(token, step2.json.task.id);
console.log('step 2 (history without reasoning):', events2.map(e => e.type).join(' '), '| answer:', events2.filter(e => e.type === 'delta').map(e => e.data.text).join('').slice(0, 80));
const acct = await j('GET', '/v2/account', { token });
console.log('quota after:', JSON.stringify(acct.json.subscription.windows.weekly));
console.log('usage:', JSON.stringify((await j('GET', '/v2/usage', { token })).json.records.map(r => ({ model: r.model, points: r.points, in: r.inputTokens, cached: r.cachedInputTokens, out: r.outputTokens }))));
