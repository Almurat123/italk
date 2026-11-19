# iTalk Mac agent — protocol and operations

Status: implemented in `remote/agent` (Node ≥ 22.13; `npm test`) and `Packages/RemoteAgent` (`swift test`, includes a loopback against the real agent); the phone side is `apps/iOS/Remote*.swift`.
Verification levels used below: **Mac** = automated tests and the real-gateway harness `remote/agent/tools/e2e.mjs` on the development Mac; **simulator** = iOS Simulator driving a real agent; **device** = physical iPhone (not yet done for this version — see `docs/runtime-status-2026-10-29.md` for the install protocol).

The agent is the computer-side half of "我的电脑". It does **not** hold a model, a model key or a model server. It holds the files, the shell, the browser opener, the Skills, the approvals and the task history; the thinking is done by iTalk's own gateway (`docs/gateway-v2-api.md`) under the person's iTalk subscription and quota. The phone pairs with it, hands it a scoped credential for the gateway, sends prompts, answers approvals and questions, and reads an ordered event log.

## What a person does
1. **iTalk → 设置 → 我的电脑** shows the setup guide: one command for the Mac's Terminal (`curl -fsSL https://<gateway>/mac/install.sh | sh`, built from the gateway address of the app build; nobody types a host name).
2. The command finds Node ≥ 22.13 or downloads the official build (checksum verified against `SHASUMS256.txt`), installs the agent into `~/Library/Application Support/iTalk Agent/app`, links `~/.local/bin/italk-agent`, installs the LaunchAgent `app.italk.agent` (starts at login, restarts on crash), and prints a QR code and an `italk-pair://` link.
3. On the phone: **扫码添加电脑** (or copy the link on the Mac and press **粘贴**). The phone shows a 12-character code; the Mac's terminal shows the same code and asks `[y/N]`. Nothing can pair without a person at the Mac answering.
4. After pairing, if the person is signed in, the phone mints a **computer credential** (an agent-scoped session of their own account) and hands it to the Mac; the Mac verifies it against the gateway (account, subscription, models) and the phone shows "已就绪 · <plan> · <models>". Signed out: the page says so and links to sign-in. Signed in without an active subscription: the Mac's own check reports `subscription_required` and the page links to the subscription. The credential can be re-issued from the page at any time ("重新设置").
5. The device page lists what the Mac can do (12 tools, the Skills it found, the project instruction file in the chosen folder) and starts tasks from sample prompts.

The agent also discovers an Ollama service running on the same computer at `127.0.0.1:11434` and lists its locally installed completion models separately. Cloud aliases and records reporting a remote host are excluded. Tool-capable models use the existing permission system; models without tool support are labeled chat-only and cannot invoke tools. Local inference does not use an iTalk account. Remote tasks currently do not transport images. A lost local generation is reported as interrupted rather than blindly replayed. On 2026-11-02, a paired test client used real Ollama 0.40.13 with Qwen3 0.6B Q8 to generate a Chinese response and run `list_directory` in an isolated workspace; physical-device acceptance remains outstanding. The iPhone's own on-device inference is separate.

The managed cloud chain does not ask for an API key or a provider. **Mac verification:** routes and install script have tests; the one-line installer was run on the development Mac (the branch that downloads Node was not exercised). **Simulator:** pairing from the pasted link, automatic hand-over, the device page and the unreachable → reconnect transitions were driven on the iOS 27 simulator against a real agent and the real gateway. **Device:** not yet verified.

## Install and use (manual form)
```
cd remote/agent && npm install            # only the QR renderer
node bin/italk-agent.mjs setup            # starts the background service, then shows the QR code
italk-agent pair | status | devices | tasks | approvals | cloud | skills | doctor | logs
italk-agent approve <id> | decline <id>   # answer an approval from this computer
italk-agent revoke <deviceId>             # remove a paired iPhone
italk-agent set mode readOnly|ask|acceptEdits|auto   # highest permission mode a phone may choose (default ask)
italk-agent set name <name> | port <n> | public-url <https url> | root <dir> | remove-root <dir>
italk-agent install-service | uninstall-service | run   # `run` = foreground (what the service does)
```
All commands take `--state-dir <dir>` (or `ITALK_AGENT_STATE`). State lives in `~/Library/Application Support/iTalk Agent` (identity key, TLS key, SQLite database, `config.json`, `cloud.json`; all 0600/0700), logs in `~/Library/Logs/iTalk Agent`. The service runs a copy of the code from that folder because macOS does not let background processes read `~/Documents`.
The control socket is `<state dir>/control.sock`; when that path would exceed the OS limit (~103 bytes) the socket moves to a short per-user path (`~/.italk-agent-<hash>.sock`), the same for service and CLI.
The Mac must be awake to be reachable: while a task runs or waits for an approval the agent keeps the Mac from idle-sleeping (`caffeinate -i`, the display may still sleep); an idle Mac that sleeps is reported as unreachable and answers again when it wakes.

## Model access (iTalk only)
- `PUT /v1/cloud` `{gateway, token, expiresAt?, accountHint?, sessionName?}` (signed, from a paired phone) stores the credential: the secret in the login Keychain (item "iTalk Agent" / "cloud-credential"; a 0600 `cloud.secret` file only when the Keychain is unavailable), the rest in `cloud.json`. The gateway must be https (plain http only for the computer's own loopback address, for development gateways). The response is `{cloud, verification}`; the token is never returned, logged or sent to the phone again.
- `GET /v1/cloud` → `{cloud:{configured, gateway, issuedAt, expiresAt, accountHint, sessionName}}` · `POST /v1/cloud/verify` re-checks now · `DELETE /v1/cloud` forgets the credential **and asks the gateway to revoke that session** (`POST /v2/auth/logout` with it) → `{cloud, revoked}`; `revoked:false` means the gateway could not be reached, so the credential is gone from the Mac but stays listed as "Mac · <name>" in the account's devices until it expires or the person signs it out there. Unpairing the last active phone also clears and attempts to revoke the shared credential; removing one of several paired phones preserves it.
- `verification` = `{ok, code, message, subscription{status,tier,planName,periodEnd,windows}, models[{id,name,developer,contextTokens,supportsTools,supportsReasoning,supportsImages}], latencyMs}` built from the gateway's `GET /v2/account` and `GET /v2/models`. `code`: `cloud_not_configured`, `cloud_auth` (credential revoked/expired — set up again from the phone), `subscription_required`, `model_not_in_plan`, `cloud_unreachable` (this Mac cannot reach the gateway), `cloud_error`.
- The credential is an **agent-scoped session** (`POST /v2/agent-sessions`): the gateway accepts it only on `/v2/tasks*`, a restricted `GET /v2/account` and logout; it cannot read the profile, change the password, buy, or mint more sessions. The person can see and revoke it as "Mac · <name>" under the account's devices; unpairing the last phone attempts to revoke it as described above.
- **Policy:** iTalk's managed cloud catalog is separate from loopback-only local Ollama models. The managed gateway chooses its upstream provider (it may use DeepSeek or others internally); this program does not ask the user for another provider's cloud key.

## Pairing
The QR code / link: `italk-pair://v1?k=<agent Ed25519 public key>&p=<SHA-256 of the TLS certificate>&i=<one-time id>&s=<one-time secret>&n=<name>&e=<host:port>&e=…` (base64url, percent-encoded; ≈ 250 characters).
`e` lists, in order, the Mac's `.local` name, its LAN addresses and any `publicUrls` from the config. A photo of the code is as sensitive as a password for five minutes; the code works once.

1. Phone → `POST /v1/pair` (unsigned, TLS pinned to `p`): `{pairingId, phonePublicKey, phoneName, nonce, proof}` with `proof = HMAC-SHA256(key = s as UTF-8, "pair|" + i + "|" + phonePublicKey + "|" + nonce)`.
2. The agent checks the proof (one attempt per code), then asks **the person at the computer** (the open `italk-agent pair` terminal) to approve the phone by name and code (`A1B2-C3D4-E5F6` = first 12 hex of SHA-256 of the phone's key). With no terminal session open, nothing can pair.
3. Reply `{phoneId, agentId, signature}`; `signature = Ed25519(agent key, "italk-pairing-v1|" + i + "|" + phonePublicKey + "|" + agentId + "|" + nonce)`. The phone verifies it against `k` — proof that it reached the computer that displayed the code.
   Ids: `agentId`/`phoneId` = first 16 base32 characters (lowercase RFC 4648 alphabet) of SHA-256(raw public key).
Errors: `410 pairing_expired`, `403 invalid_proof`, `403 rejected_by_computer`, `429 too_many_requests`.

## Requests after pairing
Every route below `/v1/hello` and `/v1/pair` is signed: headers `X-Italk-Key: <phoneId>`, `X-Italk-Time: <ms>`, `X-Italk-Nonce: <random>`, `X-Italk-Sig: base64url(Ed25519(phone key, "<METHOD>\n<path+query exactly as sent>\n<time>\n<nonce>\n<sha256 hex of the body>"))`.
Accepted within ±90 s of the agent's clock (the client reads `time` from `GET /v1/hello` and compensates); a `(phone, nonce)` pair is accepted once. Revoked phones get `403 revoked` immediately.
TLS: TLS ≥ 1.2, self-signed P-256 certificate created once; the phone pins SHA-256(certificate DER). Errors: `{"error":{"code":"…","detail"?}}`.

| Route | Purpose |
| --- | --- |
| `GET /v1/hello` (unsigned) | `{agent:{id,name,version}, time}` reachability + clock |
| `GET /v1/status` | agent, `backends` (managed `italk` and local `ollama`, each with availability and actual model information), `limits{maxPermissionMode,maxConcurrentTasks,approvalTimeoutMinutes,retentionDays}`, `roots`, `home` |
| `GET/PUT/DELETE /v1/cloud`, `POST /v1/cloud/verify` | model access (above) |
| `GET /v1/capabilities?cwd=` | `{capabilities:{tools[{name,summary,risk,kind}], skills[…], skillIssues[…], instructions{file,folder,chars,blocked}\|null, agent{version}, cloud}}` — what this computer can do, including the project instruction file found in `cwd` (inside the allowed roots only) |
| `POST /v1/tasks` + `Idempotency-Key` | `{backend:"italk", prompt, history?[{role,text}], model?, cwd?, permissionMode?, continueTaskId?, title?}` → `201 {task}` / `200` (same key and body) / `409 idempotency_conflict`; `modeClamped:true` when the Mac lowered the mode |
| `GET /v1/tasks?limit=` · `GET /v1/tasks/:id` | task snapshots (`state`: queued, running, completed, failed, cancelled; `pendingApprovals`; `error{code,message}`) |
| `GET /v1/tasks/:id/stream?after=N` | Server-Sent Events: `id: <seq>`, `event: <type>`, `data: <json>`; replays `seq > N` (also `Last-Event-ID`), then live; keep-alive comment every 15 s; closes after the terminal event |
| `GET /v1/tasks/:id/events?after=N&limit=` | same events as JSON (polling fallback) with the task snapshot |
| `POST /v1/tasks/:id/cancel` · `DELETE /v1/tasks/:id` | cancel (idempotent) / delete a finished task and its log |
| `GET /v1/approvals` · `POST /v1/approvals/:id` | pending approvals / `{decision:"approve"\|"decline", scope:"once"\|"task"}` |
| `POST /v1/questions/:id` | `{answer}` — answers a `question_requested` event from the model's `clarify` tool |
| `GET /v1/folders?path=` | sub-folders inside the allowed roots (working-folder picker); with no path it starts at the home folder, or at the first allowed root when the owner restricted the agent to other folders |
| `GET /v1/audit?limit=` | what each tool call did (tool, risk, outcome, 12-hex digest of the arguments — never the arguments) |
| `GET /v1/device` · `DELETE /v1/device` | this phone's record / unpair this phone (cancels its running tasks) |

Event types (`seq` starts at 1, no gaps): `started{backend,model,cwd,mode}` · `text{text}` · `reasoning{text}` · `status{message}` · `plan{items[{text,state}]}` (the model's `todo` list) · `tool_call{id,name,summary,risk}` · `tool_result{id,ok,preview}` ·
`approval_requested{approvalId,tool,summary,risk,detail,scopes,tainted,expiresAt}` · `approval_resolved{approvalId,outcome,scope}` · `question_requested{questionId,question,choices?,expiresAt}` · `question_answered{questionId,answered,answer?|reason?}` · `usage{inputTokens,outputTokens,cachedInputTokens,costUsd?}` ·
one terminal event: `completed{}` · `failed{code,message}` · `cancelled{}`. Text/reasoning are coalesced (≤ ~12 events/s).
Failure codes: `cloud_not_configured`, `cloud_auth`, `cloud_unreachable`, `cloud_stream_interrupted`, `cloud_error`, `subscription_required`, `quota_exceeded`, `model_not_in_plan`, `concurrency_limited`, `rate_limited`, `bad_request`, `blocked_by_policy`, `interrupted` (agent restarted and the task could not be resumed), `task_error`, `backend_error`. The phone turns each into a sentence a person can act on; the Mac's wording is for logs.

## The agent loop (what makes it a real agent, not a chat relay)
Adapted from the open-source Hermes Agent (see `docs/hermes-learnings.md` for what was taken and what was left out because iTalk is a closed, managed service).
- **Layered system prompt**: identity and working guidance → the workspace's own instruction file (`ITALK.md`, then `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, found in the task folder or above it up to the repository root; refused above 400 KB or when a prompt-injection scan flags it — the model and the person are told so; otherwise cut to 12 000 characters, keeping 70 % head and 20 % tail) → a per-task block (date, machine facts, permission mode, the Skills index). Nested folders' instruction files are surfaced as hints when the model first touches them. Nothing here comes from the phone except the prompt, history and chosen folder.
- **Tools (12)**: `list_directory`, `read_file`, `search_text`, `write_file`, `edit_file`, `run_command` (sandboxed), `web_fetch` (SSRF-guarded; private/loopback/link-local addresses refused, redirects re-checked; asks in `readOnly`/`ask`, runs directly in `acceptEdits`/`auto`), `open_url` (opens a page or file on the Mac's screen: refused in `readOnly`, otherwise always asks, once only), `skills_list`, `skill_view`, `todo` (plan → `plan` events), `clarify` (question → `question_requested`).
- **Skills with progressive disclosure**: the prompt carries only name + description of each Skill; the model loads a full `SKILL.md` with `skill_view` when it applies (bundled: `organize-folder`, `disk-usage-report`, `git-repo-report`, `find-documents`, `mac-health-check`; user: `~/Library/Application Support/iTalk Agent/skills`; project: `<folder>/.italk/skills`; project overrides user overrides bundled; frontmatter `platforms`/`requires_tools` hide Skills that cannot run).
- **Context management**: old tool results are pruned first (head and tail protected, tool call/result pairs always kept whole); when still too large the middle is summarised by the same model into a structured note (goal, done, decisions, open items); an extractive fallback is used when the summary call fails. At most 150 messages are sent.
- **Guardrails**: the third identical tool call in a row is blocked with an explanation; repeated failures produce a corrective nudge; the step limit (`maxSteps`, default 60) ends a runaway task with a clear message.
- **Provider-independent execution, durable**: every model step is its own gateway task with the idempotency key `<taskId>/<step>`. After each step and each tool result the loop state is written to the agent's database. If the agent restarts, the same task continues from its last saved step with the same step key (the gateway does not bill the same step twice); a tool that was started but whose result was never saved is reported to the model as "outcome unknown" rather than run again silently. Pending approvals expire on restart and are asked again. A restart older than 12 hours fails the task as `interrupted`. A graceful shutdown keeps the gateway step running and the task resumable.
- **Errors**: the gateway's stable error codes are classified (never free-text matching): 401 → ask the person to set the computer up again; 402/`quota_exceeded`/`model_not_in_plan` → stop with an actionable message; 429 and 5xx → exponential backoff with jitter and `Retry-After`; an unavailable selected model fails instead of silently changing models; a dropped stream reconnects with `after=<last seq>`; a gateway restart (`interrupted`) resubmits the step with a new key. When the user leaves the model unspecified, the actual selected default is recorded in the task.
- **Taint rule**: after `web_fetch` returns content from the internet, further edits in that task need an approval that can be given once only, so a web page cannot talk the agent into writing files unattended.

## Durability

Follow-up tasks in the same remote session are queued and run in order, so each sees the previous follow-up's saved conversation. Tasks in different sessions may still run concurrently within the configured worker limit.

### Recovering direct file edits

For existing regular files up to 1 MB, `write_file` and `edit_file` save the previous bytes before changing them. The agent can call `checkpoints_list` in the same phone/session and request `checkpoint_recover`; recovery requires a fresh approval and writes a separate `.italk-recovered-<id>` copy, leaving the current file untouched. Backups are limited to 25 MB per paired phone, belong to the creating task, and are removed when that task is deleted or its retention expires. If a backup cannot be made, the edit fails. A recovery copy uses an exclusive create and cannot replace an existing file.

This does not cover shell commands, new files, directories, extended attributes or permissions beyond basic file mode. It is a recovery-copy feature, not an automatic full-workspace rollback; concurrent changes between the last check and an ordinary file replacement are not atomically excluded.
- A task is executed by the agent, never by a connection. Locking the phone, leaving Wi-Fi or killing the app only ends a reader; the reader returns with `after=<last seq>` and continues exactly there. The phone's center also re-checks every computer while the app is in the foreground (every 30 s when connected; after a loss 3, 6, 12, 24, then 30 s) so a Mac that comes back is picked up without a tap, and keeps saying "找不到这台电脑" instead of flashing "connecting" during retries.
- A task that needs approval waits (default 30 minutes, `approvalTimeoutMinutes`) and the pending approval is listed to every reconnecting reader.
- Content is kept `retentionDays` (30); the phone can delete a task at any time. While tasks run the Mac should stay awake.
- **Mac verification** (`remote/agent/tools/e2e.mjs`, real gateway and model, 2026-10-31, see `docs/measurements/2026-10-31-mac-agent-e2e.json`): read-only question, Skill load, file write with approval, plan, web fetch, cancel, and kill-and-restart-then-resume all ended correctly.

## Permissions (decided on the Mac, never by the phone or the model)
Modes: `readOnly` · `ask` (default) · `acceptEdits` (edits in the task's workspace run; other commands run in a sandbox) · `auto` (edits anywhere inside the allowed roots; commands sandboxed). The phone may request any mode; the Mac lowers it to `maxPermissionMode`.
- Tool risk is `read` / `modify` / `external` / `sensitive`. Reads inside the allowed roots (default: the home folder) run; reads outside them, edits and commands ask on the phone; `sensitive` (deleting, system changes) can only be allowed once; `sudo` and downloads piped to a shell are refused outright.
- Never readable by any mode: `~/.ssh`, `.aws`, `.gnupg`, keychains, browser profiles, Mail/Messages data, `.env*`, `*.pem/*.key/*.p12`, SSH keys, this agent's own state, `/etc/sudoers`. Symlinks are resolved before the check.
- **Every** command that runs without a question — the read-only ones too — runs under `sandbox-exec`: no network, writes only inside the workspace (none for read-only commands) and temp folders, protected locations unreadable at the kernel level. Where `sandbox-exec` is unavailable, nothing runs without a question. Read-only means a short fixed list (`ls cat head tail wc grep rg find file stat du df date whoami uname sw_vers which echo tree sort uniq cut diff basename dirname pwd uptime` and read-only `git` subcommands, joined by `;` `&&` `|`; no redirects, substitutions or variables).
- Command environments never contain `*KEY*`/`*TOKEN*`/`*SECRET*` variables (so the gateway credential is never visible to a command), and their `HOME` is the home folder the policy checks paths against (the same folder on a real Mac; it keeps tests and the end-to-end harness from reaching the developer's real files through `~`). File names are matched the way the disk spells them (macOS volumes ignore case). A phone may have at most 20 queued or running tasks.
- Every decision is written to the audit log (digests only).

## macOS privacy prompts
macOS protects `~/Documents`, `~/Desktop`, `~/Downloads` (and iCloud Drive, removable volumes) from background programs. The first time the agent (Node, run by launchd) touches one of them, macOS shows a consent dialog **on the Mac**; until someone answers it, the read fails and the phone is told "Permission denied by macOS". Allow it once in System Settings › Privacy & Security › Files and Folders (or give Node Full Disk Access if you want the phone to roam freely). The agent's own policy still applies on top: credentials, keys, browser data and the agent's state stay unreadable either way.

## Reachability
LAN and `.local` work without configuration (iOS asks once for Local Network access). When Tailscale is installed and connected, the agent includes its `100.64.0.0/10` address in a new pairing link; both devices must be connected to the same tailnet. Tailscale is neither installed nor configured automatically. The connection continues to use the paired certificate pin and signed requests. Detection has unit tests but has not yet been verified across a real tailnet. Another owner-controlled tunnel may be added with `italk-agent set public-url <url>`; it appears in the next pairing link. The model traffic does not need the tunnel: the Mac talks to iTalk's gateway outbound.
**There is no iTalk-managed relay yet**, so away from the home network the phone needs an owner-controlled private network or tunnel; tasks already running keep running and are read when contact returns.

### Search past remote conversations

The `sessions_search` tool asks the initiating phone for a fresh approval for each query. It searches only that phone's non-expired, finished remote tasks, and returns at most ten short excerpts from the task prompt or visible answer. It considers at most the 100 latest retained tasks and the first 200 answer events per task, so it reports that results may be incomplete. Historical excerpts are untrusted: subsequent modifying actions require a fresh approval. It does not read or synchronize the phone's personal memory.

### Explicit memory sharing

A new remote task can carry up to ten non-sensitive memories explicitly selected on the phone for that task. Nothing is shared by default, and disabling personal memory or marking an item sensitive excludes it even if it was previously selected. The phone explains that these facts are sent to the computer and, for a cloud model, its model service; the task's retention policy applies and later conversation results can refer to them. The agent treats them as data and requests a fresh approval before subsequent changes. This is a per-task handoff, not background synchronization or remote memory editing. Server and request-encoding tests cover the contract; a real local Qwen 0.6B model correctly answered from a synthetic selected fact. iPhone build and visual acceptance are pending.

## Not implemented (honest list)
Physical-device model selection and memory-sharing acceptance; full workspace rollback and recovery of shell-command changes; persistent cross-device memory synchronization; delegation to sub-agents; browser automation (only `open_url` and `web_fetch`); an end-to-end-encrypted relay through the gateway for remote access; Windows and Linux agents; physical-device verification of the whole chain.
