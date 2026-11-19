# What iTalk took from Hermes Agent (and what it did not)

Source studied: <https://github.com/NousResearch/hermes-agent> (README, `AGENTS.md`, the developer guide and user guide pages, and the core modules `agent/conversation_loop.py`, `context_compressor.py`, `prompt_builder.py`, `system_prompt.py`, `subdirectory_hints.py`, `tool_guardrails.py`, `error_classifier.py`, `retry_utils.py`, `turn_recovery.py`, `session_persistence.py`, `tools/approval.py`, `tools/skills_tool.py`, `tools/checkpoint_manager.py`, `toolsets.py`), read on 2026-10-30/31. Nothing was copied verbatim; the designs were re-implemented in Node for the Mac agent (`remote/agent/src/agent/*`, MIT-licensed upstream, see `docs/licenses.md`).

The Mac agent supports iTalk's managed cloud service and discovers locally installed Ollama models through its loopback API. The app also retains its separate on-device inference. The managed gateway chooses its upstream provider internally. User-configured cloud provider keys and third-party OAuth were not carried over from Hermes. The Ollama integration has passed a paired-client test against Qwen3 0.6B on a Mac; physical-device acceptance remains pending.

| Hermes capability | iTalk status | Where / why |
| --- | --- | --- |
| Layered system prompt (identity → workspace context → per-turn facts) | **Adopted** | `agent/prompt.mjs`: guidance, then the workspace instruction file, then a task block (date, machine facts, permission mode, Skills index). The prompt is assembled on the Mac per task; the phone cannot inject system text. |
| Workspace context files (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, …) with injection scanning and head/tail truncation | **Adopted** | `ITALK.md` > `AGENTS.md` > `CLAUDE.md` > `.cursorrules`; found in the task folder or above (up to the repo root); refused above 400 KB or when `agent/safety.mjs` flags prompt-injection phrases (the refusal is visible to the model and the person); cut to 12 000 characters (70 % head, 20 % tail). |
| Subdirectory hints (instruction files of folders the agent walks into) | **Adopted** | surfaced the first time a tool touches a folder with its own instruction file. |
| Skills with progressive disclosure (`skills_list`, `skill_view`, `SKILL.md` frontmatter, platform filters) | **Adopted** | `agent/skills.mjs`; bundled/user/workspace precedence; five bundled Mac skills (`remote/agent/skills`). Skills are plain files, so the same format works in the phone's own Skill system (`docs/skill-packages.md`). |
| Skills hub / installing skills from third-party registries | **Not adopted** | untrusted code and prompts from outside iTalk's catalog; Skills reach the Mac only from the bundle, the owner's skills folder or the project. |
| Tool registry with schemas, risk, result truncation | **Adapted** | 12 tools (`tools.mjs`, `agent/loop.mjs`); each has a risk class the Mac's policy decides on. No plugin tool loading. |
| Tool Search (deferred schemas for many MCP/plugin tools) | **Not needed yet** | only 12 built-in tools; revisit with MCP. |
| Planning tool (`todo`) | **Adopted** | becomes `plan` events; the phone renders a live checklist. |
| Clarifying questions (`clarify`) | **Adopted** | `question_requested` / `question_answered`; answered from the phone (`POST /v1/questions/:id`), expires like an approval. |
| Context compression (prune old tool output, protect head and tail, structured summary by the same model, extractive fallback, never split a tool call from its result) | **Adopted** | `agent/context.mjs`; 150-message cap. Micro-compaction (amortised summaries) and prompt-cache-aware prefixes were **not** implemented; the gateway's provider-side cache is used as it is. |
| Tool-call guardrails (repeat detection, failure nudges) | **Adopted** | `agent/guardrails.mjs`: third identical call is blocked with an explanation. |
| Error classification, jittered backoff, `Retry-After`, stream reconnect | **Adopted, simplified** | `cloud.mjs` classifies the gateway's stable error codes (no free-text matching). An unavailable selected model fails explicitly rather than silently switching models. |
| Provider-independent execution | **Adapted** | the loop uses the gateway's durable-task API for managed cloud and a separate loopback Ollama adapter for local models. |
| Persistent sessions, crash recovery (`turn_recovery`, state DB) | **Adopted, stricter** | agent state is saved after every step and tool result; a restart resumes with the same step key so the gateway does not bill twice; a tool whose result was never saved is reported as "outcome unknown", never silently re-run. |
| Dangerous-command approvals (pattern detection, once/session/always) | **Adapted** | decisions are made on the Mac's policy (risk classes, sandbox), asked on the phone with `once`/`task` scopes; `sensitive` actions can only be allowed once; there is no "always" and no allow-list the model can extend. |
| Taint tracking after reading untrusted web content | **Added by iTalk** | after `web_fetch`, edits in that task need a once-only approval. |
| Sandboxed command execution | **Added by iTalk** | every command that runs without a question runs under `sandbox-exec` (no network, scoped writes). |
| Checkpoints and rollback of file edits | **Partial** | `write_file` and `edit_file` save bounded preimages; a separately approved recovery creates a new copy without replacing the current file. Shell commands, newly created files and full-workspace rollback remain unsupported. See `docs/mac-agent-api.md`. |
| Memory tool, session search, user model | **Not on the Mac yet** | the phone has its own memory (`apps/iOS/MemoryCenter.swift`); sharing it with the Mac agent needs a decision about what leaves the phone. |
| Delegation / sub-agents, parallel tool execution | **Not yet** | one model step at a time keeps cost and approvals understandable. |
| Persistent goals (`/goal` judge loop) | **Not yet** | tasks end when the model says it is done or the step limit (60) is reached. |
| Context references (`@file`, `@folder`, `@url`) | **Not yet** | the phone picks a working folder; `@`-style references are a UI feature to add later. |
| Multi-platform messaging gateway (Telegram, Discord, …), cron, voice | **Not applicable** | iTalk's phone app is the front end; scheduled work is a separate decision. |
| Browser automation / cloud browsers via a managed tool gateway | **Not yet — and the right shape for it** | Hermes routes web search, browser and image tools through its subscription ("one subscription, every tool, no extra keys"). iTalk should do the same: run these tools **server-side behind the iTalk gateway** under the same quota, so the Mac needs no keys for them either. Today the Mac has only `web_fetch` and `open_url`. |
| User-configurable cloud providers, OAuth to third-party model accounts, "bring your own key" | **Not carried over** | iTalk's cloud catalog is managed. Computer-hosted models use a separate loopback-only integration. |

## What changed in iTalk because of this study
- The Mac agent went from "an OpenAI-compatible chat relay with six tools and optional wrappers around other agents" to **one** backend (`italk`) with the loop above. The wrappers (Claude Code, Codex, ACP) and the Keychain-stored provider key were removed from the agent, the CLI, the phone app and the docs.
- The gateway gained **agent-scoped sessions** so a Mac can use the person's subscription without being able to read the profile or buy anything (`POST /v2/agent-sessions`).
- The phone gained the first-run guide, automatic model-access hand-over, capability discovery, plan/approval/question rendering and automatic reconnection (`docs/mac-agent-api.md`).

## Verification
**Mac:** unit and protocol tests for every row marked adopted (`remote/agent/test`, 40+ tests) and a real-gateway, real-model run of read / skill / write-with-approval / plan / web / cancel / restart-resume (`remote/agent/tools/e2e.mjs`, `docs/measurements/2026-10-31-mac-agent-e2e.json`). **Simulator:** the phone pages driving a real agent. **Physical iPhone:** not yet.
Known limits of that evidence: one model family (DeepSeek through the gateway) was exercised; prompt-injection resistance was tested with the scanner's patterns and the taint rule, not with an adversarial benchmark.
