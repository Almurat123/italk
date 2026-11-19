# iTalk documentation index

Start with **`CHECKPOINT-runtime.md`** (where the backend work stands and how to resume) and **`WORK_COORDINATION.md`** (who owns what; contracts between the backend and UI sessions). Dates are 2026; "verified" always names where.

## Contracts (typed, tested)
| Document | What it fixes |
| --- | --- |
| `gateway-v2-api.md` | Cloud gateway v2: accounts, sessions, computer credentials (agent-scoped sessions), the public `/mac` installer routes, plans, usage, purchases, durable model tasks with replayable streams |
| `mac-agent-api.md` | The Mac agent (iTalk cloud models only): one-line install, QR pairing, model-access hand-over, signed requests, durable tasks/events/plans/questions, the agent loop, approvals, permission modes, macOS privacy notes |
| `hermes-learnings.md` | What was taken from Hermes Agent (and deliberately not: user-configurable providers/keys), adopted / not yet / removed, with where each lives |
| `skill-packages.md` | Installing skills from other people: format, trust, fencing/taint, install/update/rollback, the declared HTTPS tools |
| `companion-cue-contract.md` | What the character may know: ordered `CompanionCue` snapshots (phase, real mic/speech levels, tool/approval/outcome events, reconnection, model switching) and optional model-declared tone cues; availability per signal and per model |
| `agent-event-protocol.md`, `conversation-contract.md`, `interactive-ui-contract.md` | Run events, conversation store, approval/UI components (earlier contracts, still current) |

## Operations and economics
| Document | What it covers |
| --- | --- |
| `deploy-gateway.md` | Running the gateway (Mac or VM), tunnels, environment, the `/v1` retirement plan |
| `economics.md` | Point units, plan arithmetic, worst-case margins, calibration |
| `licenses.md` | Third-party license inventory (engineering, not legal advice) |
| `model-distribution.md`, `local-first-model-architecture.md` | How local models are described, downloaded, verified |

## Architecture notes
`agent-platform.md` (one registry for every model) · `voice-architecture.md`, `voice-assistant-research-design.md` (capture, TTS, turn-taking) · `remote-integration-research.md` (the 2026-10-27 survey that preceded the Mac agent) · `v1-acceptance-matrix.md` (what is verified on a real iPhone).

## Evidence
`measurements/` — dated JSON from real runs: agent benchmark (Mac), iPhone capture/MOSS probes, Mac-link probe on the iOS Simulator, Smart Turn comparison. `voice-samples/` — the shipping voices reading four test sentences. `benchmarks/` — earlier benchmark notes.

## UI/design notes (UI session)
`character-*`, `chat-*`, `compact-recording-v14.md`, `conversation-ui.md`, `expressive-character-v9.md`, `liquid-character-v8.md`, `ui-reference-audit.md`, `art/`.

## Not documents but worth knowing
`remote/agent` (Node Mac agent, `npm test`), `server/` (gateway, `npm test`), `Packages/*` (`swift test`), `tools/` (benchmarks, voice and model tooling, turn-taking evaluation). Rules for builds and disk: `AGENTS.md`.
