// Test fixture: the real v2 gateway with a scripted provider, an in-memory database and a pre-subscribed account, plus dev-only
// controls to break connections on purpose. Prints one JSON line {port, token} when ready.
//   node tools/fake-gateway.mjs
import { openDb } from '../src/v2/db.mjs';
import { createApp } from '../src/v2/app.mjs';
import { Pricing } from '../src/v2/plans.mjs';

if (process.env.NODE_ENV === 'production') process.exit(1);
const stats = { providerCalls: 0, lastMessages: null };
const provider = {
  async *generate(request) {
    stats.providerCalls++; stats.lastMessages = request.messages;
    const last = request.messages.at(-1)?.text ?? '';
    const parts = last.includes('长') ? Array.from({ length: 12 }, (_, i) => `第${i + 1}段。`) : ['你好', '，', '世界'];
    yield { type: 'reasoning', text: '先想一想。' };
    for (const p of parts) { await new Promise(r => setTimeout(r, last.includes('长') ? 250 : 20)); if (request.signal?.aborted) return; yield { type: 'delta', text: p }; }
    if (last.includes('工具')) yield { type: 'tool_call', id: 'call_1', name: 'weather_forecast', arguments: '{"place":"杭州"}' };
    yield { type: 'usage', inputTokens: 120, cachedInputTokens: 64, outputTokens: 30, reasoningTokens: 4, searches: 0 };
    yield { type: 'finish', reason: last.includes('工具') ? 'toolCalls' : 'stop' };
  },
};
const db = openDb(':memory:');
const app = createApp({ db, pricing: new Pricing(), provider, accountsOptions: { scryptParams: { N: 1 << 10, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 } } });
const sockets = new Set();
app.server.on('connection', (s) => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
const original = app.server.listeners('request')[0];
app.server.removeAllListeners('request');
app.server.on('request', (req, res) => {
  if (req.url === '/__dev/drop') { for (const s of sockets) if (s !== req.socket) s.destroy(); res.end('{}'); return; }
  if (req.url === '/__dev/stats') { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(stats)); return; }
  original(req, res);
});
await new Promise(r => app.server.listen(0, '127.0.0.1', r));
const port = app.server.address().port;
const reg = await (await fetch(`http://127.0.0.1:${port}/v2/auth/register`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'e2e@example.com', password: 'e2e-password-1' }) })).json();
const now = Date.now();
db.prepare('INSERT INTO subscriptions(original_transaction_id,account_id,product_id,status,environment,period_start,expires_at,auto_renew,updated_at) VALUES(?,?,?,?,?,?,?,?,?)')
  .run('e2e', reg.account.id, 'com.italk.cloud.monthly', 'active', 'Sandbox', now, now + 30 * 86_400_000, 1, now);
console.log(JSON.stringify({ port, token: reg.session.token }));
