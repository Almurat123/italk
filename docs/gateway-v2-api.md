# iTalk gateway v2 — API contract

Status: **contract + server implementation in `server/src/v2`** (`node --test test/*.test.mjs test/v2/*.test.mjs` in `server/`: 63 tests). A route is marked *live* when it has a passing test in `server/test/v2`; the client
must read `GET /v2/capabilities` and show a feature only when the server says it is available (nothing is faked on the phone).

Base URL: `/v2`. JSON in, JSON out, UTF-8. Authenticated routes need `Authorization: Bearer <session token>`.
Errors: HTTP status + `{"error":{"code":"quota_exceeded","message":"…","detail":{…}}}`. Codes are stable machine strings; `message` is for logs.

## Capabilities (public)
`GET /v2/capabilities` →
```json
{ "environment": "development|production", "registration": true, "passwordReset": false, "emailVerification": false,
  "signInWithApple": false, "subscriptions": false, "taskRetentionHours": 24, "version": "2.0.0" }
```
`passwordReset`/`emailVerification` are true only when a mailer is configured; `signInWithApple` only when the bundle id is configured;
`subscriptions` only when the App Store credentials/root certificates are configured. Until then the corresponding routes answer `503 feature_unavailable`.

## Accounts and sessions
| Route | Body → Response |
| --- | --- |
| `POST /v2/auth/register` | `{email, password(≥8), displayName?, device?{name,platform}}` → `201 {account, session}` · `email_taken`, `invalid_email`, `weak_password`, `too_many_attempts` |
| `POST /v2/auth/login` | `{email, password, device?}` → `{account, session}` · `invalid_credentials`, `too_many_attempts` |
| `POST /v2/auth/apple` | `{identityToken, nonce?, fullName?{given,family}, device?}` → `{account, session, isNewAccount}` · `invalid_identity_token`, `feature_unavailable` |
| `POST /v2/auth/logout` · `logout-all` | → `204` |
| `POST /v2/auth/password-reset/request` | `{email}` → `202 {}` always (no account enumeration) · `feature_unavailable` when no mailer |
| `POST /v2/auth/password-reset/confirm` | `{token, newPassword}` → `204`, every session revoked · `invalid_token` |
| `POST /v2/auth/email/verify/request` (auth) · `…/confirm {token}` | → `202` / `204` |

`session = {token, expiresAt(ms)}`; store the token in the Keychain; sessions slide (90 days since last use) and can be revoked.
`account = {id, email, emailVerified, displayName, hasAvatar, avatarVersion, appleAccountToken, createdAt, signInMethods:["password","apple"]}`.
`appleAccountToken` is the UUID the app must pass as `appAccountToken` when buying, so a purchase can only be attached to the account that made it.

## Computer credentials (agent-scoped sessions)
A paired Mac thinks through this gateway, with a credential for **the person's own account** that can do less than a normal sign-in.
- `POST /v2/agent-sessions` (full session only) `{name?}` → `201 {session:{token, expiresAt, name}}`. `name` becomes the device label `Mac · <name>` (≤ 60 characters). Setting up the same computer again revokes its earlier credential; at most **8** computer credentials are active per account (the least recently used is revoked first). Lifetime 30 days, sliding with use.
- The token is a normal bearer token with `scope = "agent"`. It may call **only**: `GET /v2/account` (answers `{subscription, models}` — no profile, e-mail or avatar), `POST /v2/auth/logout`, and the model-task routes `POST /v2/tasks`, `GET /v2/tasks/:id`, `GET /v2/tasks/:id/stream|events`, `POST /v2/tasks/:id/cancel`. Everything else answers `403 forbidden_scope` — it cannot read or change the profile, change the password, buy, restore purchases, list or revoke other sessions, delete the account, or mint more credentials.
- Its model use is billed to the account exactly like the phone's: same subscription check, same quota windows, same concurrency limit, same `model_not_in_plan` rule.
- It is listed in `GET /v2/account/sessions` under its label and revoked with `DELETE /v2/account/sessions/:id`, `POST /v2/auth/logout-all`, a password change (every other session), a password reset, or account deletion. The Mac revokes it itself (`POST /v2/auth/logout`) when the person removes the computer on the phone.
- There is no way for a person or a client to name another provider or key here: the provider is chosen by the gateway operator (`MODEL_PROVIDER`, `MODEL_API_KEY`, `MODEL_ID`, `MODEL_BASE_URL` in the server's environment; DeepSeek today) and never appears in a response except as the model id the plan lists.

## The Mac program (public)
So that "install on the Mac" is one line the phone can show. Nothing here is secret; the program is verified against its checksum by the installer.
| Route | Answer |
| --- | --- |
| `GET /mac/install.sh` | the installer script with this gateway's address filled in. `503 feature_unavailable` when the gateway does not know its public address |
| `GET /mac/italk-agent.tgz` · `GET /mac/italk-agent.tgz.sha256` · `GET /mac/version.json` | the agent package (< 1 MB, built by `node scripts/package-mac-companion.mjs`), its SHA-256, and `{version, sha256, builtAt}` |
`PUBLIC_URL` (`https://host[:port]`, no path; `http://` only for a development gateway, which the Mac agent also accepts only on its own loopback address) is the address written into the installer and into the phone's copy-and-paste command. Without it only a request that reached the gateway on `127.0.0.1`/`localhost` is answered (development).

## Profile (authenticated)
| Route | Body → Response |
| --- | --- |
| `GET /v2/account` | → `{account, subscription, models}` (`subscription` as below) |
| `PATCH /v2/account` | `{displayName(1–40)}` → `{account}` |
| `PUT /v2/account/avatar` | raw image bytes, `Content-Type: image/png|jpeg|webp`, ≤ 512 KB → `{account}` · `unsupported_image`, `image_too_large` |
| `GET /v2/account/avatar` | → image bytes, `ETag` = `avatarVersion` · `404` when none |
| `DELETE /v2/account/avatar` | → `{account}` |
| `POST /v2/account/password` | `{current, next}` → `204`, other sessions revoked |
| `GET /v2/account/sessions` · `DELETE /v2/account/sessions/:id` | devices signed in (including `Mac · …` computer credentials) / sign one out |
| `DELETE /v2/account` | `{password}` (Apple-only accounts: `{identityToken}`) → `204`. Removes name, email, avatar, sessions and stored task content; keeps only anonymous ledger rows required for tax/refund records |
| `GET /v2/usage?limit=50` | → `{records:[{id,date,model,points,inputTokens,cachedInputTokens,outputTokens,estimated}]}` |

## Subscription, quota, purchases
```json
"subscription": { "status": "none|active|grace|billing_retry|expired|revoked|refunded", "planId": "com.italk.cloud.monthly", "tier": "plus",
  "planName": "…", "periodStart": 0, "periodEnd": 0, "autoRenew": true, "concurrency": 2, "models": ["deepseek-flash"],
  "windows": { "weekly": {"limit":1800,"used":12.4,"remaining":1787.6,"startsAt":0,"resetsAt":0}, "period": { … } } }
```
Units are **points** (1 point = ¥0.001 of provider cost); `windows` is null without an active subscription. Weekly windows are counted from the period start.
- `GET /v2/plans` (public) → plans: `{productId, tier, period, name, periodPoints, weeklyPoints, concurrency, models}`; prices come from StoreKit, never from here.
- `GET /v2/models` (public) → `{id, name, developer, usageWeight, contextTokens, supportsTools, supportsReasoning, supportsImages, note?}`; `usageWeight` is the cost relative to the baseline model.
- `POST /v2/iap/transactions {signedTransactions:[JWS]}` (auth) → `{subscription}`. Used after a purchase and for **Restore Purchases**. Each JWS is verified against Apple's root, the bundle id and the environment; its `appAccountToken` must equal the caller's `appleAccountToken`.
- `POST /v2/iap/notifications {signedPayload}` — App Store Server Notifications V2 (called by Apple). Idempotent by `notificationUUID`.

## Durable model steps ("tasks")
A task is one model step of an agent run. The gateway executes it **independently of the connection** and keeps an ordered event log; any number of readers
may attach, leave and come back.
- `POST /v2/tasks` + header `Idempotency-Key: <≥8 chars, stable per run step, e.g. "<runId>/<step>">`
  body `{model, messages[{role,text,toolCalls?,toolCallId?,reasoningContent?}], tools[{name,description,parameters}], maxTokens, images?, reasoningEffort?: none|low|high|max, runId?, step?}`
  → `201 {task}` (new) or `200 {task}` (same key and same request: the existing task, nothing is billed twice) · `409 idempotency_conflict` (same key, different request)
  · `402 subscription_required` · `429 quota_exceeded{window:"weekly|period",resetsAt}` / `too_many_concurrent_requests` / `too_many_attempts` · `403 model_not_in_plan`.
  Quota is reserved **before** anything is sent to a provider.
- `GET /v2/tasks/:id` → `{task:{id,state,model,runId,step,createdAt,finishedAt,lastSeq,finishReason,error,usage}}`; `state`: `queued|running|completed|failed|cancelled`.
- `GET /v2/tasks/:id/stream?after=N` — Server-Sent Events. Each event: `id: <seq>`, `event: <type>`, `data: <json>`. Replays stored events with `seq > N` (or `Last-Event-ID`),
  then streams live ones; `: keep-alive` comment every 15 s; closes after the terminal event. Reconnect with the last `seq` you applied; events are never repeated or skipped.
- `GET /v2/tasks/:id/events?after=N&limit=500` — the same events as plain JSON (polling fallback, background fetch).
- `POST /v2/tasks/:id/cancel` → `{task}` (idempotent). Billing covers what was actually produced.
- `GET /v2/tasks?limit=20` → recent tasks.

Event types: `started{model}` · `reasoning{text}` · `delta{text}` · `tool_call{id,name,arguments}` · `usage{inputTokens,cachedInputTokens,outputTokens,reasoningTokens}` ·
terminal (exactly one): `completed{finishReason: stop|toolCalls|length}` · `failed{code}` · `cancelled{}`. `reasoning`/`delta` events are coalesced (≤ ~12/s) and must be applied in `seq` order.
A gateway restart ends in-flight tasks as `failed{code:"interrupted"}` with their partial events kept; resubmit with a **new** idempotency key.
Task content (request and events) is deleted `taskRetentionHours` after the task ends; ids, state, token counts and cost remain.

## Limits
Request body ≤ 4 MB (images ≤ 3 × ~1 MB base64), messages ≤ 200, tools ≤ 64, `maxTokens` ≤ 4000. Login/registration are rate limited per address and per email.

## Not available yet (answers `503 feature_unavailable`)
Sign in with Apple needs the capability in the app and `APPLE_BUNDLE_ID`; password reset/e-mail verification need an SMTP/API mailer; purchases need App Store Connect products and the
App Store Server API credentials (verification of transactions and notifications works offline against Apple's published roots and is tested with a synthetic chain).
