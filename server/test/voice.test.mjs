import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { VoiceProvider, DeliveryPrefix } from '../src/voice.mjs';
import { Ledger } from '../src/ledger.mjs';
import { createGateway } from '../src/server.mjs';
import { ModelProvider } from '../src/provider.mjs';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const providerConfig = { apiKey: 'fixture', baseURL: 'https://example.test/v1', model: 'speech-2.8-turbo', voiceId: 'Chinese (Mandarin)_Warm_Bestie' };
const success = () => ({ base_resp: { status_code: 0 }, data: { status: 2, audio: '49443300' }, extra_info: { usage_characters: 7, word_count: 99, audio_format: 'mp3' } });

test('speech uses model emotion control and bills reported characters, not word count', async () => {
  const payloads = [];
  const provider = new VoiceProvider(providerConfig, async (_url, request) => {
    assert.equal(request.redirect, 'error'); payloads.push(JSON.parse(request.body));
    return Response.json(success());
  });
  assert.equal((await provider.synthesize({ text: '太好了！', emotion: 'happy' })).characters, 7);
  await provider.synthesize({ text: '现在是三点。', emotion: 'neutral' });
  assert.equal(payloads[0].voice_setting.emotion, 'happy');
  assert.equal(payloads[0].voice_setting.pitch, 0);
  assert.equal(payloads[1].voice_setting.emotion, undefined);
  assert.equal(payloads[0].output_format, 'hex');
});

test('speech rejects partial, unmetered, invalid, and extra-voice-fee responses', async () => {
  for (const mutate of [
    value => { delete value.extra_info.usage_characters; },
    value => { value.data = null; },
    value => { value.data.status = 1; },
    value => { value.data.audio = 'https://example.test/audio'; },
    value => { value.extra_info.usage_voice_count = 1; },
    value => { value.base_resp.status_code = 1000; }
  ]) {
    const value = success(); mutate(value);
    const provider = new VoiceProvider(providerConfig, async () => Response.json(value));
    await assert.rejects(provider.synthesize({ text: '你好', emotion: 'calm' }), /voice_usage_or_audio_invalid/);
  }
});

test('delivery prefix survives token fragmentation and never enters displayed text', () => {
  const prefix = new DeliveryPrefix(), output = [];
  for (const chunk of ['[emo', 'tion:hap', 'py]\n', '太好了！']) output.push(...prefix.push(chunk));
  output.push(...prefix.push('', true));
  assert.deepEqual(output, [{ type: 'delivery', emotion: 'happy' }, { type: 'delta', text: '太好了！' }]);
  const ordinary = new DeliveryPrefix();
  assert.deepEqual(ordinary.push('你好'), [{ type: 'delivery', emotion: 'neutral' }, { type: 'delta', text: '你好' }]);
  const invalid = new DeliveryPrefix();
  assert.deepEqual(invalid.push('[emotion:unknown]\n你好', true), [{ type: 'delivery', emotion: 'neutral' }, { type: 'delta', text: '你好' }]);
});

test('speech usage has an explicit character unit and settles once', () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const id = randomUUID();
  ledger.reserve({ id, accountId: 'a', digest: 'voice', maximum: 100, kind: 'voice', model: 'speech', rates: { characters: 1_000_000 } });
  assert.equal(ledger.settleVoice(id, 7), 7);
  assert.equal(ledger.settleVoice(id, 90), 7);
  assert.equal(ledger.account('a').balance, 993);
  assert.equal(ledger.usage('a')[0].characters, 7);
  assert.equal(ledger.usage('a')[0].kind, 'voice');
  assert.equal(ledger.usage('a')[0].inputTokens, 0);
  ledger.close();
});

test('old text ledgers retain balances and usage when character billing is added', () => {
  const directory = mkdtempSync(join(tmpdir(), 'italk-voice-migration-'));
  const path = join(directory, 'ledger.sqlite');
  let ledger = new Ledger(path);
  try {
    ledger.topUp('a', 1000, 'fixture');
    ledger.db.exec('ALTER TABLE turns DROP COLUMN kind; ALTER TABLE turns DROP COLUMN characters');
    ledger.close(); ledger = new Ledger(path);
    assert.equal(ledger.account('a').balance, 1000);
    const id = randomUUID();
    ledger.reserve({ id, accountId: 'a', digest: 'text', maximum: 100, model: 'text', rates: { input: 1_000_000, output: 0, search: 0 } });
    assert.equal(ledger.settle(id, { inputTokens: 9, outputTokens: 0 }), 9);
    assert.equal(ledger.usage('a')[0].kind, 'text');
    assert.equal(ledger.usage('a')[0].characters, 0);
  } finally { ledger.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('model delivery is separate from answer text and a tag-only answer is rejected', async () => {
  for (const answer of ['[emotion:calm]\n慢慢来。', '[emotion:calm]']) {
    const provider = new ModelProvider({ apiKey: 'fixture', model: 'fixture', protocol: 'responses', baseURL: 'https://example.test', maxOutput: 100 }, async () => {
      const events = [{ type: 'response.output_text.delta', delta: answer }, { type: 'response.completed', response: { usage: { input_tokens: 10, output_tokens: 20 } } }];
      return new Response(events.map(value => `data: ${JSON.stringify(value)}\n\n`).join(''));
    });
    const output = [];
    const read = async () => { for await (const value of provider.respond({ text: '你好' })) output.push(value); };
    if (answer.includes('慢慢来')) {
      await read(); assert.deepEqual(output[0], { type: 'delivery', emotion: 'calm' });
      assert.equal(output.filter(value => value.type === 'delta').map(value => value.text).join(''), '慢慢来。');
    } else await assert.rejects(read(), /provider_usage_unavailable/);
  }
});

test('speech relay gates consent and configuration before reserving, then rejects replay', async () => {
  const ledger = new Ledger(); ledger.topUp('a', 1000, 'fixture');
  const token = 'v'.repeat(32), account = { id: 'a', token, scopes: ['cloudAI'] };
  let dispatched = 0;
  const voice = { configured: true, async synthesize() { dispatched++; return { audio: Buffer.from('ID3fixture'), characters: 7 }; } };
  const config = { accounts: [account], rates: { input: 1, output: 1, search: 0 }, maxOutput: 10, products: {}, voice: { model: 'speech', characters: 1_000_000 } };
  const server = createGateway({ config, ledger, provider: { configured: false }, purchases: {}, voice });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const body = { requestId: randomUUID(), text: '太好了，已经完成。', emotion: 'happy', voiceConsent: true, healthConsent: false };
  const post = value => fetch(`http://127.0.0.1:${server.address().port}/v1/speech`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value)
  });
  try {
    assert.equal((await post(body)).status, 403);
    account.scopes.push('cloudVoice');
    assert.equal((await post({ ...body, voiceConsent: false })).status, 403);
    assert.equal((await post({ ...body, text: '今天走了123步。' })).status, 403);
    voice.configured = false;
    assert.equal((await post(body)).status, 503);
    assert.equal(ledger.account('a').available, 1000); assert.equal(dispatched, 0);
    voice.configured = true;
    const response = await post(body);
    assert.equal(response.status, 200); assert.equal(response.headers.get('content-type'), 'audio/mpeg');
    assert.equal(response.headers.get('x-italk-charged'), '7');
    assert.equal(await response.text(), 'ID3fixture');
    assert.equal((await post(body)).status, 409);
    assert.equal(ledger.account('a').balance, 993); assert.equal(dispatched, 1);
    voice.synthesize = async () => { throw new Error('provider failed'); };
    assert.equal((await post({ ...body, requestId: randomUUID() })).status, 503);
    assert.equal(ledger.account('a').balance, 993);
    assert.equal(ledger.account('a').available, 993 - Buffer.byteLength(body.text));
    assert.equal(ledger.usage('a')[0].status, 'uncertain');
  } finally { await new Promise(resolve => server.close(resolve)); ledger.close(); }
});
