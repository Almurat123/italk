import test from 'node:test';
import assert from 'node:assert/strict';
import { OllamaAccess, OllamaModelClient } from '../src/ollama.mjs';
import { startPaired } from './helpers.mjs';

function fakeOllama() {
  const requests = [];
  const fetcher = async (url, options = {}) => {
    requests.push({ url, ...options });
    assert.ok(url.startsWith('http://127.0.0.1:11434/'));
    assert.equal(options.redirect, 'error');
    if (url.endsWith('/api/tags')) return Response.json({ models: [{ name: 'qwen:local' }, { name: 'cloud:cloud' }, { name: 'alias:latest', remote_host: 'https://example.com' }, { name: 'plain:latest' }] });
    if (url.endsWith('/api/show')) {
      const { model } = JSON.parse(options.body);
      return Response.json({ capabilities: model === 'plain:latest' ? ['completion'] : ['completion', 'tools'], model_info: { 'qwen.context_length': 32768 } });
    }
    if (url.endsWith('/api/chat')) {
      const body = JSON.parse(options.body);
      const result = body.messages.some(m => m.role === 'tool')
        ? [{ message: { content: '完成' }, done: false }, { done: true, prompt_eval_count: 3, eval_count: 2 }]
        : [{ message: { tool_calls: [{ function: { name: 'list_directory', arguments: { path: '.' } } }] }, done: false }, { done: true }];
      const bytes = new TextEncoder().encode(result.map(v => JSON.stringify(v)).join('\n') + '\n');
      const split = bytes.indexOf(0xe5) + 1;
      const stream = new ReadableStream({ start(controller) { controller.enqueue(bytes.slice(0, split > 0 ? split : 1)); controller.enqueue(bytes.slice(split > 0 ? split : 1)); controller.close(); } });
      return new Response(stream, { status: 200 });
    }
    throw new Error('unexpected URL');
  };
  return { fetcher, requests };
}

test('local discovery excludes remote aliases and reports tool capabilities', async () => {
  const fake = fakeOllama(), access = new OllamaAccess({ fetcher: fake.fetcher });
  const result = await access.verify();
  assert.equal(result.ok, true);
  assert.deepEqual(result.models.map(m => m.id), ['qwen:local', 'plain:latest']);
  assert.equal(result.models[0].contextTokens, 32768);
  assert.equal(result.models[1].supportsTools, false);
  assert.ok(!fake.requests.some(r => r.body?.includes('cloud:cloud') || r.body?.includes('alias:latest')));
  const unavailable = await new OllamaAccess({ fetcher: async () => { throw new Error('offline'); } }).verify();
  assert.equal(unavailable.code, 'local_unavailable');
});

test('paired phone runs local model tools without a cloud account and gets streamed UTF-8', async () => {
  const fake = fakeOllama(), ctx = await startPaired({ localFetcher: fake.fetcher });
  try {
    const status = (await ctx.phone.call('GET', '/v1/status')).json;
    assert.equal(status.backends.find(b => b.id === 'italk').available, false);
    assert.deepEqual(status.backends.find(b => b.id === 'ollama').models, ['qwen:local', 'plain:latest']);
    const created = await ctx.phone.call('POST', '/v1/tasks', { backend: 'ollama', model: 'qwen:local', prompt: 'list files', cwd: ctx.workspace }, { headers: { 'idempotency-key': 'local-test-123456' } });
    assert.equal(created.status, 201);
    const end = await ctx.phone.stream(created.json.task.id, {});
    assert.ok(end.events.some(e => e.type === 'tool_result' && e.data.ok));
    assert.equal(end.events.filter(e => e.type === 'text').map(e => e.data.text).join(''), '完成');
    assert.equal(end.events.at(-1).type, 'completed');
    assert.equal(fake.requests.filter(r => r.url.endsWith('/api/chat')).length, 2);
    const second = fake.requests.filter(r => r.url.endsWith('/api/chat'))[1];
    assert.equal(JSON.parse(second.body).messages.find(m => m.role === 'tool').tool_name, 'list_directory');
  } finally { await ctx.stop(); }
});

test('unavailable explicit model never falls back to another local or cloud model', async () => {
  const fake = fakeOllama(), access = new OllamaAccess({ fetcher: fake.fetcher });
  const client = new OllamaModelClient({ access, fetcher: fake.fetcher });
  await assert.rejects(client.step({ model: 'cloud:cloud', messages: [], tools: [] }), { code: 'local_model_unavailable' });
  assert.equal(fake.requests.filter(r => r.url.endsWith('/api/chat')).length, 0);
});

test('a model without tool support cannot execute an unsolicited tool call', async () => {
  const fake = fakeOllama(), ctx = await startPaired({ localFetcher: fake.fetcher });
  try {
    const created = await ctx.phone.call('POST', '/v1/tasks', { backend: 'ollama', model: 'plain:latest', prompt: 'list files', cwd: ctx.workspace }, { headers: { 'idempotency-key': 'no-tools-test-123' } });
    const end = await ctx.phone.stream(created.json.task.id, {});
    assert.equal(end.events.at(-1).type, 'failed');
    assert.equal(end.events.at(-1).data.code, 'local_model_error');
    assert.ok(!end.events.some(e => e.type === 'tool_call'));
    const chat = JSON.parse(fake.requests.find(r => r.url.endsWith('/api/chat')).body);
    assert.deepEqual(chat.tools, []);
    assert.match(chat.messages[0].content, /cannot access files/i);
  } finally { await ctx.stop(); }
});

test('a slow cloud service does not indefinitely hide a local model', async () => {
  const fake = fakeOllama();
  const delayed = () => new Promise(resolve => setTimeout(() => resolve(Response.json({ error: 'late' }, { status: 503 })), 4500));
  const ctx = await startPaired({ localFetcher: fake.fetcher, fetcher: delayed, gateway: 'https://cloud.example.com' });
  try {
    const started = Date.now();
    const result = await ctx.phone.call('GET', '/v1/status');
    assert.ok(Date.now() - started < 6000, 'status has a bounded wait');
    assert.equal(result.json.backends.find(b => b.id === 'ollama').available, true);
    assert.equal(result.json.backends.find(b => b.id === 'italk').detail, 'probe_timeout');
  } finally { await ctx.stop(); }
});

test('real local Ollama model responds through a paired agent', { skip: process.env.ITALK_REAL_OLLAMA !== '1', timeout: 180_000 }, async () => {
  const ctx = await startPaired();
  try {
    const status = (await ctx.phone.call('GET', '/v1/status')).json;
    const local = status.backends.find(b => b.id === 'ollama');
    assert.ok(local?.available && local.models.includes('qwen3:0.6b'), 'the real local model is discovered');
    const created = await ctx.phone.call('POST', '/v1/tasks', { backend: 'ollama', model: 'qwen3:0.6b', prompt: '用一句中文介绍你自己。', cwd: ctx.workspace }, { headers: { 'idempotency-key': 'real-local-test-123' } });
    assert.equal(created.status, 201);
    const end = await ctx.phone.stream(created.json.task.id, {});
    assert.equal(end.events.at(-1).type, 'completed', JSON.stringify(end.events.at(-1)));
    assert.ok(end.events.some(e => e.type === 'text' && e.data.text.trim()), 'the real model generated text');
  } finally { await ctx.stop(); }
});

test('real local Ollama model can call an approved read tool', { skip: process.env.ITALK_REAL_OLLAMA !== '1', timeout: 180_000 }, async () => {
  const ctx = await startPaired();
  try {
    const created = await ctx.phone.call('POST', '/v1/tasks', { backend: 'ollama', model: 'qwen3:0.6b', prompt: '请用 list_directory 工具查看当前工作文件夹里有哪些文件，然后告诉我结果。', cwd: ctx.workspace }, { headers: { 'idempotency-key': 'real-local-tool-test-123' } });
    assert.equal(created.status, 201);
    const end = await ctx.phone.stream(created.json.task.id, {});
    assert.equal(end.events.at(-1).type, 'completed', JSON.stringify(end.events.at(-1)));
    assert.ok(end.events.some(e => e.type === 'tool_call' && e.data.name === 'list_directory'), 'model actually requested the read tool');
    assert.ok(end.events.some(e => e.type === 'tool_result' && e.data.ok), 'tool actually returned a result');
  } finally { await ctx.stop(); }
});

test('real local model can use a deliberately shared test memory', { skip: process.env.ITALK_REAL_OLLAMA !== '1', timeout: 180_000 }, async () => {
  const ctx = await startPaired();
  try {
    const created = await ctx.phone.call('POST', '/v1/tasks', { backend: 'ollama', model: 'qwen3:0.6b', prompt: '根据本次提供的资料，我喜欢什么颜色？只说颜色。', sharedMemory: ['我最喜欢蓝色。'], cwd: ctx.workspace }, { headers: { 'idempotency-key': 'real-local-memory-test-123' } });
    assert.equal(created.status, 201);
    const end = await ctx.phone.stream(created.json.task.id, {});
    assert.equal(end.events.at(-1).type, 'completed', JSON.stringify(end.events.at(-1)));
    const answer = end.events.filter(e => e.type === 'text').map(e => e.data.text).join('');
    assert.match(answer, /蓝/);
  } finally { await ctx.stop(); }
});
