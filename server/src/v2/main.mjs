import { createPublicKey } from 'node:crypto';
import { SignedDataVerifier, Environment } from '@apple/app-store-server-library';
import { openDb } from './db.mjs';
import { createApp } from './app.mjs';
import { Pricing, DEFAULT_PRICING, DEFAULT_PLANS } from './plans.mjs';
import { ModelProvider } from '../provider.mjs';
import { createMailer } from './mailer.mjs';
import { AppleSignIn, loadAppleRoots } from './apple.mjs';
import { readFileSync, existsSync } from 'node:fs';

const env = process.env;
const log = (event, fields = {}) => console.log(JSON.stringify({ t: new Date().toISOString(), event, ...fields }));

const providerKind = env.MODEL_PROVIDER === 'deepseek' ? 'deepseek' : 'generic';
const provider = env.MODEL_API_KEY ? new ModelProvider({
  apiKey: env.MODEL_API_KEY, providerKind, model: env.MODEL_ID ?? 'deepseek-flash', protocol: env.MODEL_PROTOCOL ?? 'chat-completions',
  baseURL: (env.MODEL_BASE_URL ?? 'https://api.deepseek.com').replace(/\/+$/, ''), maxOutput: Math.min(Number(env.MAX_OUTPUT_TOKENS) || 800, 4000),
}) : null;

const pricing = new Pricing(
  env.PRICING_FILE && existsSync(env.PRICING_FILE) ? JSON.parse(readFileSync(env.PRICING_FILE, 'utf8')) : DEFAULT_PRICING,
  env.PLANS_FILE && existsSync(env.PLANS_FILE) ? JSON.parse(readFileSync(env.PLANS_FILE, 'utf8')) : DEFAULT_PLANS);

const bundleId = env.APPLE_BUNDLE_ID || 'com.italk.assistant';
const roots = loadAppleRoots(env.APPLE_ROOT_CERTS_DIR);
const appleEnv = env.APPLE_ENVIRONMENT === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
const verifier = roots.length && (appleEnv !== Environment.PRODUCTION || env.APPLE_APP_ID)
  ? new SignedDataVerifier(roots, env.APPLE_ONLINE_CHECKS === '1', appleEnv, bundleId, env.APPLE_APP_ID ? Number(env.APPLE_APP_ID) : undefined) : null;
const appleSignIn = env.APPLE_SIGN_IN === '1' ? new AppleSignIn({ bundleId, fetchKeys: async () => (await (await fetch('https://appleid.apple.com/auth/keys')).json()).keys }) : null;

const db = openDb(env.DB_PATH ?? './data/italk.sqlite');
// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: The owner's development phone needs an encrypted LAN connection to the Mac gateway.
// Debug Goal: Offer explicit certificate-backed HTTPS without changing production or silently falling back to HTTP.
// Search Tags: developer gateway local network tls certificate
// Invariants:
// - A partially configured certificate fails startup.
// - Private keys are read from local files, never sent to the client.
// Failure Modes:
// - Falling back to HTTP exposes the developer password and session.
// - Binding to an unintended address exposes the development gateway.
if (Boolean(env.DEV_TLS_CERT) !== Boolean(env.DEV_TLS_KEY)) throw new Error('Both DEV_TLS_CERT and DEV_TLS_KEY are required');
if (env.DEV_TLS_CERT && env.NODE_ENV === 'production') throw new Error('Developer TLS configuration is unavailable in production');
const tls = env.DEV_TLS_CERT ? { cert: readFileSync(env.DEV_TLS_CERT), key: readFileSync(env.DEV_TLS_KEY) } : null;
const app = createApp({ db, pricing, provider, mailer: createMailer(env), appleSignIn, verifier, environment: env.NODE_ENV === 'production' ? 'production' : 'development',
                        retentionMs: (Number(env.TASK_RETENTION_HOURS) || 24) * 3_600_000, trustProxy: env.TRUST_PROXY === '1', publicUrl: env.PUBLIC_URL || null, tls, log });
const port = Number(env.V2_PORT ?? 8795), host = env.V2_HOST ?? '127.0.0.1';
app.server.listen(port, host, () => log('listening', { host, port, provider: Boolean(provider), apple: Boolean(verifier), mail: Boolean(createMailer(env)) }));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { log('shutdown', { signal }); await app.close(); db.close(); process.exit(0); });
