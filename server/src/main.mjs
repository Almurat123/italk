import { Ledger } from './ledger.mjs';
import { ModelProvider } from './provider.mjs';
import { PurchaseVerifier } from './purchases.mjs';
import { createGateway } from './server.mjs';
import { VoiceProvider } from './voice.mjs';

const env = process.env;
function integer(name, fallback) {
  const n = Number(env[name] ?? fallback);
  if (!Number.isSafeInteger(n) || n < 0 || n > 1e9) throw new Error(`Invalid ${name}`);
  return n;
}
const accounts = env.CLIENT_ACCOUNTS_JSON ? JSON.parse(env.CLIENT_ACCOUNTS_JSON) : env.CLIENT_TOKEN ? [{ id: env.CLIENT_SUBJECT ?? 'owner', token: env.CLIENT_TOKEN, scopes: ['cloudAI', 'research', ...(env.MODEL_SUPPORTS_IMAGES === 'true' ? ['cloudImages'] : [])] }] : [];
if (accounts.some(a => !a.id || typeof a.token !== 'string' || a.token.length < 32 || !Array.isArray(a.scopes))) throw new Error('Invalid client account configuration');
if (new Set(accounts.map(a => a.token)).size !== accounts.length) throw new Error('Duplicate account token');
const providerKind = env.MODEL_PROVIDER ?? 'generic';
if (!['generic', 'deepseek'].includes(providerKind)) throw new Error('Invalid MODEL_PROVIDER');
const baseURL = new URL(env.MODEL_BASE_URL ?? (providerKind === 'deepseek' ? 'https://api.deepseek.com' : 'https://api.openai.com/v1'));
if (baseURL.protocol !== 'https:' || baseURL.username || baseURL.password || baseURL.search || baseURL.hash) throw new Error('Provider URL must be HTTPS without credentials/query');
const protocol = env.MODEL_PROTOCOL ?? (providerKind === 'deepseek' ? 'chat-completions' : 'responses');
if (providerKind === 'deepseek' && (baseURL.hostname !== 'api.deepseek.com' || protocol !== 'chat-completions')) throw new Error('DeepSeek requires the official HTTPS endpoint and chat-completions');
if (providerKind === 'deepseek' && env.MODEL_ID && !['deepseek-flash', 'deepseek-v4-pro'].includes(env.MODEL_ID)) throw new Error('Unsupported DeepSeek model');
const voiceURL = new URL(env.VOICE_BASE_URL ?? 'https://api.minimax.io/v1');
if (voiceURL.protocol !== 'https:' || voiceURL.username || voiceURL.password || voiceURL.search || voiceURL.hash) throw new Error('Voice URL must be HTTPS without credentials/query');
if (!['responses', 'chat-completions'].includes(protocol)) throw new Error('Invalid MODEL_PROTOCOL');
const config = {
  accounts, protocol, providerKind, baseURL: baseURL.href.replace(/\/$/, ''), apiKey: env.MODEL_API_KEY, supportsImages: env.MODEL_SUPPORTS_IMAGES === 'true', reasoningSummary: env.MODEL_REASONING_SUMMARY === 'true',
  model: env.MODEL_ID ?? (providerKind === 'deepseek' ? 'deepseek-flash' : 'gpt-6-luna'), maxOutput: Math.min(integer('MAX_OUTPUT_TOKENS', 800), 2000),
  rates: { input: integer('INPUT_MICROCREDITS_PER_MILLION', 1e6), output: integer('OUTPUT_MICROCREDITS_PER_MILLION', 5e6), search: integer('SEARCH_MICROCREDITS', 100000) },
  products: JSON.parse(env.STORE_PRODUCTS_JSON ?? '{}'),
  voice: { apiKey: env.VOICE_API_KEY, baseURL: voiceURL.href.replace(/\/$/, ''),
    model: env.VOICE_MODEL_ID ?? 'speech-2.8-turbo', voiceId: env.VOICE_ID ?? 'Chinese (Mandarin)_Warm_Bestie',
    characters: integer('VOICE_MICROCREDITS_PER_MILLION_CHARACTERS', 1e6) }
};
const ledger = new Ledger(env.DATABASE_PATH ?? './data/gateway.sqlite');
ledger.recoverInterrupted();
const server = createGateway({ config, ledger, provider: new ModelProvider(config), purchases: new PurchaseVerifier(env), voice: new VoiceProvider(config.voice) });
server.listen(integer('PORT', 8787), env.HOST ?? '127.0.0.1', () => console.log('iTalk gateway ready; no prompt or health payload logging'));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { ledger.close(); process.exit(0); }));
