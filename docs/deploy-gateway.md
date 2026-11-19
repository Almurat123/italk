# Running the iTalk gateway

## What runs
`server/src/v2/main.mjs` (Node ≥ 22.13): accounts, sessions, subscriptions, quota, durable model tasks. State is one SQLite file (`DB_PATH`, WAL). Provider keys exist only in this
process's environment. Legacy `/v1` routes (`server/src/main.mjs`) are for already-installed development builds only.

## Environment
| Variable | Meaning |
| --- | --- |
| `MODEL_PROVIDER=deepseek`, `MODEL_API_KEY`, `MODEL_ID` | provider credentials (server only) |
| `DB_PATH` | SQLite file, default `./data/italk.sqlite` (back it up: it holds accounts, ledger, subscriptions) |
| `V2_HOST`, `V2_PORT` | listen address (default 127.0.0.1:8795; put TLS in front) |
| `TRUST_PROXY=1` | read the client address from `X-Forwarded-For` (behind Caddy/Cloudflare) |
| `PUBLIC_URL` | the https address people reach this gateway at (`https://api.example.com`). It is written into the Mac installer served at `/mac/install.sh`; without it the installer is only served to requests that arrived on `127.0.0.1`/`localhost` |
| `TASK_RETENTION_HOURS` | how long conversation content of finished tasks is kept (default 24) |
| `MAIL_API_URL`, `MAIL_API_KEY`, `MAIL_FROM` | transactional-mail HTTP API for password reset / e-mail verification (without it those features report unavailable); `MAIL_MODE=console` prints codes in development |
| `APPLE_BUNDLE_ID`, `APPLE_SIGN_IN=1` | enable Sign in with Apple verification |
| `APPLE_ROOT_CERTS_DIR`, `APPLE_ENVIRONMENT`, `APPLE_APP_ID`, `APPLE_ONLINE_CHECKS` | App Store transaction/notification verification (Apple root `.cer` files from apple.com/certificateauthority) |
| `PRICING_FILE`, `PLANS_FILE` | override model prices and plans (JSON) |

## Development on the Mac
```
cd server && MAIL_MODE=console node --env-file=.env src/v2/main.mjs      # 127.0.0.1:8795
cloudflared tunnel --url http://127.0.0.1:8795                            # https://<random>.trycloudflare.com (changes on every start)
echo https://<random>.trycloudflare.com > config/cloud-endpoint.txt && node scripts/generate-project.mjs   # bake it into the next build
node tools/dev-grant.mjs ./data/italk.sqlite you@example.com             # development only: give an account a subscription
node tools/live-check.mjs https://<random>.trycloudflare.com ./data/italk.sqlite
```
**Simulator or Mac agent against the real model, nothing public:** `node server/tools/dev-sim-gateway.mjs` starts a throw-away gateway on a free loopback port with a temporary database, creates a subscribed test account and prints one JSON line (`endpoint`, `email`, `password`, plan models). The model key is read from `server/.env` by the gateway process and is never printed; the database is deleted on Ctrl-C. Launch a **Debug** simulator build against it with `SIMCTL_CHILD_ITALK_CLOUD_ENDPOINT=<endpoint> xcrun simctl launch <simulator> com.italk.assistant` (the app reads `ITALK_CLOUD_ENDPOINT` or the `italk.cloud.endpoint.override` default in Debug builds only), sign in with the printed account (设置 → 我的 iTalk), then pick the cloud model in the header model picker or 设置 › 模型中心 › iTalk 云端. Real model calls cost real (small) money. `ITALK_TEST_ENDPOINT`/`ITALK_TEST_TOKEN` are a legacy `/v1` device-only path and do not work in the simulator.
## The Mac program the gateway serves
`node scripts/package-mac-companion.mjs` builds `server/public/mac/italk-agent.tgz` (+ `.sha256`, `version.json`) from `remote/agent`; rebuild it whenever the agent changes and ship `server/public/mac/` with the server. People install with `curl -fsSL <PUBLIC_URL>/mac/install.sh | sh` (the phone's setup guide shows this exact line). The agent reaches the gateway outbound over https and holds only a revocable, agent-scoped credential (`docs/gateway-v2-api.md`).

## Stable endpoint (needs the owner)
Either a named Cloudflare tunnel on a domain the owner controls (`cloudflared tunnel login` → `tunnel create italk` → `tunnel route dns italk api.<domain>`; runs as a launchd service on the Mac),
or any VM with Node + Caddy (`api.<domain> { reverse_proxy 127.0.0.1:8795 }`). Put the final URL in `config/cloud-endpoint.txt` and regenerate. Moving from the Mac to a VM = copy `server/`, the
`.env`, and the SQLite file (stop the process first). For more than one instance or high write volume, replace `src/v2/db.mjs` with a Postgres adapter (all SQL is portable).

## Operations
Health `GET /v2/health`; JSON logs on stdout (no message content); `quota.reconcile()` runs every minute (releases abandoned holds), `tasks.purge()` hourly (deletes task content after the retention window).
Rotating the provider key = edit `.env` and restart: in-flight tasks end as `failed:interrupted` and the apps resubmit.

## Retiring the legacy `/v1` routes
Status 2026-10-30: nothing in the iOS app or the Swift packages calls them any more (the app talks to `/v2`; grep for `"/v1/` finds only Open-Meteo weather URLs and the Mac-agent routes, which belong to another service). The routes remain in `server/src/server.mjs`: `/v1/turns` (+ `DELETE /v1/turns/:id`), `/v1/generate`, `/v1/speech`, `/v1/capabilities`, `/v1/skills/:id`, `/v1/account`, `/v1/store/purchases`, `/v1/store/notifications`, and the single static `CLIENT_TOKEN` they authenticate with.
Plan, in order:
1. **Now:** treat them as frozen — no new features, no new tests; nothing may be added to `/v1` that `/v2` lacks. Do not expose a deployment that still needs them to the internet: the static client token is the weakest credential in the system.
2. **Before the first public build:** run only the v2 process (`node src/v2/main.mjs`) and do not start the legacy one (`npm start` → `src/main.mjs`); `/v2` needs neither `CLIENT_TOKEN` nor `CLIENT_SUBJECT`. Watch the access log for `/v1/` requests for one release cycle (they now get 404 from v2). Any hit means a build still in someone's hands uses them.
3. **After that cycle with zero hits:** delete `server/src/main.mjs`, `server.mjs`, `ledger.mjs`, `voice.mjs` (legacy routes, ledger and voice paths), the legacy tests, and the `STORE_PRODUCTS_JSON`, `INPUT_MICROCREDITS_PER_MILLION`, `OUTPUT_MICROCREDITS_PER_MILLION`, `SEARCH_MICROCREDITS` settings; keep `provider.mjs` (v2 uses it). Re-run `npm test` and `node tools/live-check.mjs`.
Rollback is just re-deploying the previous release; no data migration is involved (v2 has its own SQLite database).
