import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Ledger, requestDigest } from '../src/ledger.mjs';
import { createGateway } from '../src/server.mjs';
import { ModelProvider, parseSSE } from '../src/provider.mjs';
import { validateImages } from '../src/images.mjs';

const rates = { input: 1_000_000, output: 2_000_000, search: 1000 };
test('account exposes configured model identities only to authenticated users', async () => {
  const ledger = new Ledger();
  const token = 'a'.repeat(32);
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI', 'cloudVoice'] }], protocol: 'responses',
    rates, maxOutput: 100, model: 'actual-chat-model', products: {}, supportsImages: true,
    voice: { model: 'actual-voice-model', characters: 200, apiKey: 'never-return-this' } };
  const server = createGateway({ config, ledger, provider: { configured: true }, purchases: {}, voice: { configured: true } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const url = `http://127.0.0.1:${server.address().port}/v1/account`;
    assert.equal((await fetch(url)).status, 401);
    const response = await fetch(url, { headers: { authorization: `Bearer ${token}` } });
    const body = await response.json();
    assert.equal(body.model, 'actual-chat-model');
    assert.equal(body.modelConfigured, true);
    assert.equal(body.supportsImages, false);
    assert.equal(body.maxOutputTokens, 100);
    assert.equal(body.voice.model, 'actual-voice-model');
    assert.equal(body.voice.configured, true);
    assert.equal(body.voice.characters, 200);
    assert.ok(!JSON.stringify(body).includes(config.voice.apiKey));
    config.accounts[0].scopes = ['cloudAI'];
    const unentitled = await (await fetch(url, { headers: { authorization: `Bearer ${token}` } })).json();
    assert.equal(unentitled.voice.configured, false);
    config.accounts[0].scopes = ['cloudAI', 'cloudImages'];
    const imageEnabled = await (await fetch(url, { headers: { authorization: `Bearer ${token}` } })).json();
    assert.equal(imageEnabled.supportsImages, true);
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
// Minimal JPEG marker fixture exercises bounds; provider transport is mocked.
const imageFixture = { mimeType: 'image/jpeg', data: Buffer.from([255, 216, 255, 192, 0, 11, 8, 0, 1, 0, 1, 1, 1, 17, 0, 255, 217]).toString('base64') };
test('image headers are bounded and arbitrary remote URLs are rejected', () => {
  assert.equal(validateImages([imageFixture]).length, 1);
  assert.throws(() => validateImages([{ url: 'https://example.test/private' }]), /invalid_images/);
  assert.throws(() => validateImages([{ ...imageFixture, data: 'AAAA' }]), /invalid_images/);
  assert.throws(() => validateImages(Array(4).fill(imageFixture)), /invalid_images/);
  const oversized = Buffer.from(imageFixture.data, 'base64'); oversized.writeUInt16BE(4096, 7);
  assert.throws(() => validateImages([{ ...imageFixture, data: oversized.toString('base64') }]), /invalid_images/);
});
test('both provider protocols send inline image content and settle actual usage', async () => {
  for (const protocol of ['responses', 'chat-completions']) {
    let payload;
    const events = protocol === 'responses' ? [{ type: 'response.output_text.delta', delta: '描述' }, { type: 'response.completed', response: { usage: { input_tokens: 30, output_tokens: 2 } } }] : [{ choices: [{ delta: { content: '描述' } }] }, { usage: { prompt_tokens: 30, completion_tokens: 2 } }];
    const provider = new ModelProvider({ apiKey: 'fixture', model: 'fixture', protocol, baseURL: 'https://example.test', maxOutput: 10 }, async (_, request) => {
      payload = JSON.parse(request.body);
      return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''));
    });
    const result = [];
    for await (const event of provider.respond({ text: '描述', images: [imageFixture] })) result.push(event);
    const content = protocol === 'responses' ? payload.input[0].content : payload.messages[1].content;
    assert.equal(content.length, 2);
    assert.equal(protocol === 'responses' ? content[1].image_url : content[1].image_url.url, `data:image/jpeg;base64,${imageFixture.data}`);
    assert.equal(result.at(-1).inputTokens, 30);
  }
});
test('image consent and vision configuration are checked before credit reservation', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 1_000_000, 'fixture');
  const token = 'x'.repeat(32);
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI', 'cloudImages'] }], protocol: 'responses', rates, maxOutput: 100, model: 'fixture', products: {}, supportsImages: false };
  let dispatched = 0;
  const provider = { configured: true, async *respond({ images }) { dispatched++; assert.equal(images.length, 1); yield { type: 'delta', text: '描述' }; yield { type: 'usage', inputTokens: 30, outputTokens: 2 }; } };
  const server = createGateway({ config, ledger, provider, purchases: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/v1/turns`;
  const body = { turnId: randomUUID(), text: '', locale: 'zh-CN', cloudConsent: true, healthConsent: true, images: [imageFixture] };
  const post = value => fetch(url, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value) });
  try {
    assert.equal((await post(body)).status, 403);
    assert.equal((await post({ ...body, imageConsent: true })).status, 503);
    assert.equal(ledger.account('a').available, 1_000_000);
    assert.equal(dispatched, 0);
    config.supportsImages = true;
    const response = await post({ ...body, imageConsent: true });
    assert.match(await response.text(), /completed/);
    assert.equal(ledger.account('a').balance, 999966);
    assert.equal(dispatched, 1);
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
test('reservations serialize spending and settlement is idempotent', () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const turn = { id: randomUUID(), accountId: 'a', digest: 'digest', maximum: 800, model: 'test', rates };
  ledger.reserve(turn);
  assert.equal(ledger.account('a').available, 200);
  assert.throws(() => ledger.reserve({ ...turn, id: randomUUID() }));
  assert.throws(() => ledger.reserve(turn), /turn_in_progress/);
  assert.equal(ledger.settle(turn.id, { inputTokens: 100, outputTokens: 50 }), 200);
  assert.equal(ledger.settle(turn.id, { inputTokens: 999, outputTokens: 999 }), 200);
  assert.equal(ledger.account('a').balance, 800);
  assert.throws(() => ledger.reserve({ ...turn, accountId: 'b' }), /turn_conflict/);
  ledger.close();
});
test('failed calls release credits and restart never makes a duplicate call billable', () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const turn = { id: randomUUID(), accountId: 'a', digest: requestDigest({ text: 'fixture' }), maximum: 500, model: 'test', rates };
  ledger.reserve(turn); ledger.recoverInterrupted();
  assert.equal(ledger.account('a').available, 1000);
  assert.throws(() => ledger.reserve(turn), /turn_already_processed/);
  ledger.close();
});
test('dispatched work retains its reservation across interruption until actual usage is reconciled', () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const turn = { id: randomUUID(), accountId: 'a', digest: 'digest', maximum: 500, model: 'test', rates };
  ledger.reserve(turn); ledger.markDispatched(turn.id); ledger.fail(turn.id);
  assert.equal(ledger.account('a').available, 500);
  assert.throws(() => ledger.reserve({ ...turn, id: randomUUID() }), /turn_in_progress/);
  ledger.recoverInterrupted();
  assert.equal(ledger.account('a').available, 500);
  assert.equal(ledger.settle(turn.id, { inputTokens: 50, outputTokens: 25 }), 100);
  assert.equal(ledger.account('a').balance, 900);
  assert.equal(ledger.account('a').available, 900);
  ledger.close();
});
test('operator can release an uncertain hold only with an auditable reason', () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const turn = { id: randomUUID(), accountId: 'a', digest: 'digest', maximum: 500, model: 'test', rates };
  ledger.reserve(turn); ledger.markDispatched(turn.id); ledger.recoverInterrupted();
  assert.throws(() => ledger.voidUncertain(turn.id, 'short'), /invalid_reconciliation_reason/);
  assert.equal(ledger.voidUncertain(turn.id, 'provider confirms no billable usage').available, 1000);
  assert.throws(() => ledger.voidUncertain(turn.id, 'provider confirms no billable usage'), /turn_not_uncertain/);
  ledger.close();
});

test('DeepSeek agent requests disable thinking until reasoning state can be replayed', async () => {
  let payload;
  const events = [{ choices: [{ delta: { content: '你好' }, finish_reason: 'stop' }] }, { usage: { prompt_tokens: 5, completion_tokens: 2 } }];
  const provider = new ModelProvider({ providerKind: 'deepseek', apiKey: 'fixture', model: 'deepseek-flash', protocol: 'chat-completions', baseURL: 'https://api.deepseek.com', maxOutput: 20 }, async (_, request) => {
    payload = JSON.parse(request.body);
    return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''));
  });
  const result = [];
  for await (const event of provider.generate({ model: 'deepseek-v4-pro', messages: [{ role: 'user', text: '你好' }], tools: [], maxTokens: 20 })) result.push(event);
  assert.equal(payload.model, 'deepseek-v4-pro');
  assert.deepEqual(payload.thinking, { type: 'disabled' });
  assert.equal(result.find(event => event.type === 'usage').inputTokens, 5);
});

test('DeepSeek thinking replays reasoning with tool calls and sends the selected effort', async () => {
  let payload;
  const events = [{ choices: [{ delta: { content: '好' }, finish_reason: 'stop' }] }, { usage: { prompt_tokens: 5, completion_tokens: 2 } }];
  const provider = new ModelProvider({ providerKind: 'deepseek', apiKey: 'fixture', model: 'deepseek-flash', protocol: 'chat-completions', baseURL: 'https://api.deepseek.com', maxOutput: 20 }, async (_, request) => {
    payload = JSON.parse(request.body);
    return new Response(events.map(event => 'data: ' + JSON.stringify(event) + '\n\n').join(''));
  });
  const messages = [{ role: 'user', text: '查询' }, { role: 'assistant', text: '', reasoningContent: '先查询', toolCalls: [{ id: 'call1', name: 'get_time', arguments: '{}' }] }, { role: 'tool', text: '完成', toolCallId: 'call1' }];
  for await (const event of provider.generate({ messages, tools: [], maxTokens: 20, reasoningEffort: 'low' })) void event;
  assert.deepEqual(payload.thinking, { type: 'enabled' });
  assert.equal(payload.reasoning_effort, 'low');
  assert.equal(payload.messages[1].reasoning_content, '先查询');
});
test('purchase credits bind account and transaction, refunds are idempotent', () => {
  const ledger = new Ledger(), account = ledger.account('a');
  const tx = { transactionId: '1', appAccountToken: account.appAccountToken, productId: 'credits' };
  ledger.purchase('a', tx, 1000); ledger.purchase('a', tx, 1000);
  assert.equal(ledger.account('a').balance, 1000);
  assert.throws(() => ledger.purchase('b', tx, 1000), /purchase_account_mismatch/);
  ledger.refund(tx); ledger.refund(tx);
  assert.equal(ledger.account('a').balance, 0); ledger.close();
});
test('a refund arriving before receipt delivery prevents later credit replay', () => {
  const ledger = new Ledger(); const account = ledger.account('a');
  const tx = { transactionId: 'refunded-before-credit', appAccountToken: account.appAccountToken, productId: 'credits' };
  ledger.refund(tx);
  assert.throws(() => ledger.purchase('a', tx, 1000), /purchase_revoked/);
  assert.equal(ledger.account('a').balance, 0); ledger.close();
});
test('SSE parser preserves fragmented UTF-8 and CRLF', async () => {
  const encoded = new TextEncoder().encode('data: {"text":"你好"}\r\n\r\ndata: [DONE]\r\n\r\n');
  const stream = new ReadableStream({ start(c) { for (const byte of encoded) c.enqueue(Uint8Array.of(byte)); c.close(); } });
  const result = []; for await (const event of parseSSE(stream)) result.push(event);
  assert.deepEqual(result, [{ text: '你好' }]);
});
test('compatible provider requires actual usage and rejects incomplete outputs', async () => {
  const provider = new ModelProvider({ apiKey: 'fixture', model: 'fixture', protocol: 'chat-completions', baseURL: 'https://example.test', maxOutput: 10 }, async () => new Response('data: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: [DONE]\n\n'));
  await assert.rejects(async () => { for await (const event of provider.respond({ text: 'fixture' })) void event; }, /provider_usage_unavailable/);
});
test('gateway authentication, unavailable tools, health consent, charges, and retries', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 1_000_000, 'fixture');
  const token = 'x'.repeat(32);
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI'] }], protocol: 'responses', rates, maxOutput: 100, model: 'fixture', products: {} };
  let dispatched = 0;
  const provider = { configured: true, async *respond() { dispatched++; yield { type: 'delta', text: '你好' }; yield { type: 'usage', inputTokens: 20, outputTokens: 2 }; } };
  const server = createGateway({ config, ledger, provider, purchases: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  try {
    assert.equal((await fetch(base + '/v1/account')).status, 401);
    const capabilities = await (await fetch(base + '/v1/capabilities', { headers })).json();
    assert.deepEqual(capabilities.capabilities.map(c => c.id), ['conversation']);
    assert.equal((await fetch(base + '/v1/skills/research', { headers })).status, 404);
    const body = { turnId: randomUUID(), text: '我血压高怎么办', locale: 'zh-CN', cloudConsent: true };
    assert.equal((await fetch(base + '/v1/turns', { method: 'POST', headers, body: JSON.stringify(body) })).status, 403);
    const request = { ...body, text: '你好' };
    const response = await fetch(base + '/v1/turns', { method: 'POST', headers, body: JSON.stringify(request) });
    assert.equal(response.status, 200);
    const events = (await response.text()).trim().split('\n').map(JSON.parse);
    assert.equal(events.at(-1).type, 'completed');
    assert.equal(ledger.account('a').balance, 999976);
    assert.equal((await fetch(base + '/v1/turns', { method: 'POST', headers, body: JSON.stringify(request) })).status, 409);
    assert.equal(dispatched, 1);
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
test('a duplicate HTTP request cannot release another active reservation', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 10000, 'fixture');
  const token = 'a'.repeat(32), id = randomUUID();
  let release, entered;
  const gate = new Promise(resolve => { release = resolve; });
  const ready = new Promise(resolve => { entered = resolve; });
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI'] }], protocol: 'responses', rates, maxOutput: 100, model: 'fixture', products: {} };
  const provider = { configured: true, async *respond() { entered(); await gate; yield { type: 'delta', text: '完成' }; yield { type: 'usage', inputTokens: 10, outputTokens: 2 }; } };
  const server = createGateway({ config, ledger, provider, purchases: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/v1/turns`;
  const request = { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ turnId: id, text: '你好', cloudConsent: true, locale: 'zh-CN' }) };
  try {
    const original = fetch(url, request); await ready;
    const held = ledger.account('a').available;
    assert.ok(held < 10000);
    assert.equal((await fetch(url, request)).status, 409);
    assert.equal(ledger.account('a').available, held);
    release(); assert.match(await (await original).text(), /completed/);
    assert.equal(ledger.account('a').balance, 9986);
  } finally { release(); await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
test('agent generate relays tool schemas and streams complete tool calls for both protocols', async () => {
  for (const protocol of ['chat-completions', 'responses']) {
    let payload;
    const events = protocol === 'responses'
      ? [{ type: 'response.output_text.delta', delta: '我查一下' }, { type: 'response.output_item.done', item: { type: 'function_call', call_id: 'c1', name: 'calendar_list_events', arguments: '{"start":"2026-10-28"}' } }, { type: 'response.completed', response: { usage: { input_tokens: 50, output_tokens: 9 } } }]
      : [{ choices: [{ delta: { content: '我查一下' } }] }, { choices: [{ delta: { tool_calls: [{ index: 0, id: 'c1', function: { name: 'calendar_list_events', arguments: '{"start":' } }] } }] },
         { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"2026-10-28"}' } }] }, finish_reason: 'tool_calls' }] }, { usage: { prompt_tokens: 50, completion_tokens: 9 } }];
    const provider = new ModelProvider({ apiKey: 'k', model: 'm', protocol, baseURL: 'https://example.test', maxOutput: 100 }, async (_, request) => {
      payload = JSON.parse(request.body);
      return new Response(events.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join(''));
    });
    const out = [];
    const messages = [{ role: 'system', text: '系统' }, { role: 'user', text: '明天有什么安排' },
      { role: 'assistant', text: '', toolCalls: [{ id: 'c0', name: 'read_skill', arguments: '{"id":"calendar"}' }] }, { role: 'tool', text: '技能说明', toolCallId: 'c0' }];
    for await (const e of provider.generate({ messages, tools: [{ name: 'calendar_list_events', description: '查询日程', parameters: { type: 'object', properties: {} } }], maxTokens: 50 })) out.push(e);
    const call = out.find(e => e.type === 'tool_call');
    assert.deepEqual([call.id, call.name, JSON.parse(call.arguments).start], ['c1', 'calendar_list_events', '2026-10-28']);
    assert.equal(out.at(-1).reason, 'toolCalls');
    if (protocol === 'responses') { assert.equal(payload.tools[0].type, 'function'); assert.equal(payload.input[1].type, 'function_call'); assert.equal(payload.input[2].type, 'function_call_output'); }
    else { assert.equal(payload.tools[0].function.name, 'calendar_list_events'); assert.equal(payload.messages[2].tool_calls[0].id, 'c0'); assert.equal(payload.messages[3].role, 'tool'); }
  }
});
test('generate endpoint enforces consent, reserves credit and settles usage', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 1_000_000, 'fixture');
  const token = 'y'.repeat(32);
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI'] }], protocol: 'chat-completions', rates, maxOutput: 100, model: 'fixture', products: {}, supportsImages: false };
  const provider = { configured: true, async *respond() {}, async *generate() { yield { type: 'delta', text: '好' }; yield { type: 'usage', inputTokens: 20, outputTokens: 1 }; yield { type: 'finish', reason: 'stop' }; } };
  const server = createGateway({ config, ledger, provider, purchases: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/v1/generate`;
  const body = { requestId: randomUUID(), messages: [{ role: 'user', text: '你好' }], tools: [], maxTokens: 50, cloudConsent: true };
  const post = value => fetch(url, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value) });
  try {
    assert.equal((await post({ ...body, cloudConsent: false })).status, 403);
    assert.equal((await post({ ...body, requestId: randomUUID(), messages: [{ role: 'user', text: '我的血压有点高' }] })).status, 403, 'health text needs cloudHealth');
    const text = await (await post(body)).text();
    assert.match(text, /"type":"delta"/); assert.match(text, /"type":"completed"/);
    assert.equal(ledger.account('a').balance, 1_000_000 - 22);
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});

test('DeepSeek Flash selection is advertised, validated, passed upstream and recorded in the ledger', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 1_000_000, 'fixture');
  const token = 'm'.repeat(32), dispatched = [];
  const config = { accounts: [{ id: 'a', token, scopes: ['cloudAI'] }], providerKind: 'deepseek', protocol: 'chat-completions', rates, maxOutput: 100, model: 'deepseek-flash', products: {}, supportsImages: false };
  const provider = { configured: true, async *generate({ model }) { dispatched.push(model); yield { type: 'delta', text: '好' }; yield { type: 'usage', inputTokens: 20, outputTokens: 1 }; yield { type: 'finish', reason: 'stop' }; } };
  const server = createGateway({ config, ledger, provider, purchases: {} });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`, headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  const post = body => fetch(base + '/v1/generate', { method: 'POST', headers, body: JSON.stringify(body) });
  const body = { requestId: randomUUID(), messages: [{ role: 'user', text: '你好' }], tools: [], maxTokens: 50, cloudConsent: true };
  try {
    const account = await (await fetch(base + '/v1/account', { headers })).json();
    assert.deepEqual(account.models.map(model => model.id), ['deepseek-flash']);
    assert.equal((await post({ ...body, model: 'not-a-model' })).status, 403);
    assert.equal((await post({ ...body, model: 'deepseek-v4-pro' })).status, 403);
    for (const model of account.models) {
      const response = await post({ ...body, requestId: randomUUID(), model: model.id });
      assert.match(await response.text(), /"type":"completed"/);
    }
    assert.deepEqual(dispatched, ['deepseek-flash']);
    assert.deepEqual(new Set(ledger.usage('a').map(row => row.model)), new Set(dispatched));
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
test('reasoning is relayed only when the upstream model sends it', async () => {
  for (const protocol of ['chat-completions', 'responses']) {
    const withThought = protocol === 'responses'
      ? [{ type: 'response.reasoning_summary_text.delta', delta: '先查日程' }, { type: 'response.output_text.delta', delta: '好' }, { type: 'response.completed', response: { usage: { input_tokens: 5, output_tokens: 2 } } }]
      : [{ choices: [{ delta: { reasoning_content: '先查日程' } }] }, { choices: [{ delta: { content: '好' } }] }, { usage: { prompt_tokens: 5, completion_tokens: 2 } }];
    const without = withThought.filter(e => !JSON.stringify(e).includes('先查日程'));
    for (const [events, expected] of [[withThought, 1], [without, 0]]) {
      const provider = new ModelProvider({ apiKey: 'k', model: 'm', protocol, baseURL: 'https://example.test', maxOutput: 50 }, async () => new Response(events.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join('')));
      const out = []; for await (const e of provider.generate({ messages: [{ role: 'user', text: '嗨' }], tools: [], maxTokens: 20, reasoning: true })) out.push(e);
      assert.equal(out.filter(e => e.type === 'reasoning').length, expected, `${protocol}: no reasoning is invented`);
      assert.ok(out.some(e => e.type === 'delta'));
    }
  }
});
