# Companion signals — `CompanionCue` contract

Status 2026-10-31. Implemented in `Packages/AgentRuntime` (`Contracts/CompanionContracts.swift`, `Companion/*`), `Packages/RemoteAgent` (`RemoteCompanionBridge`), `apps/iOS/CompanionSignalHub.swift`. Unit-tested (AgentRuntime, AssistantCore, RemoteAgent); **not yet verified on the physical iPhone** — passing tests and a simulator build are not device acceptance.
Owner: the runtime/backend session. The character, its controller and every visual decision belong to the UI session; this document is only what the character may *know*.

## What it is
One small, provider-independent snapshot (`CompanionCue`) per change of state, ordered by a strictly increasing `sequence`. Every field is derived from something that really happened — a run event, a microphone buffer, a played audio frame, a Mac task event — never from the wording of an answer. The existing state machines stay the source of truth (`RunState`, `VoiceSession`, the Mac agent's event log); the reducer (`CompanionReducer`) owns no timer, makes no model request and invents no state.

```
AgentRunner bus ─┐                               ┌─ CompanionSignalHub.shared.cue      (@Observable snapshot)
VoiceSession ────┼─► CompanionReducer (pure) ───►┤
mic / TTS taps ──┤        ▲                      └─ CompanionSignalHub.shared.stream()  (ordered AsyncStream, bounded)
Mac task events ─┘  RemoteCompanionBridge
```

## Reading it (UI)
```swift
let hub = CompanionSignalHub.shared          // apps/iOS (iPhone target)
hub.cue                                      // latest snapshot; observable; changes at most ~30×/s while a level moves
for await cue in hub.stream() { … }          // starts with the current cue; bounded (a slow reader loses the oldest)
```
Consumer rules: apply cues in order and ignore any whose `sequence` is not larger than the last applied; use `phase` for posture, `event` for one-shot moments (each cue is delivered once), `mic.level` / `speech.level` for ears and mouth, `intent` only when `intentSource == .model`. `CompanionCue()` has public defaults, so previews and the motion playground can construct any state.

## Fields
| Field | Meaning | Availability |
| --- | --- | --- |
| `sequence`, `timestamp` | strictly increasing per hub (process lifetime); wall clock of the change | always |
| `conversationId`, `turnId`, `runId`, `taskId` | which conversation / user turn / agent run / Mac task the cue is about; all nil while idle | `taskId` only for Mac tasks |
| `origin` | `voice` (before or without a run) · `localAgent` · `cloudAgent` (iTalk cloud model) · `macAgent` | always |
| `providerId` | the model serving the current step | during a run |
| `phase` | `idle · preparing · listening · transcribing · thinking · working · awaitingApproval · speaking · completed · interrupted · cancelled · failed` (the brief's eleven plus `preparing`, asked for by the UI session) | always |
| `operation` | what the running tool does: `lookup read write communicate control compute remember skill other`, from a **fixed table over the tool's declared capability and side effect** (Mac tools: fixed table over tool name, then risk class) | only while `phase == .working` |
| `progress` | 0…1 | **unavailable**: no producer reports a fraction today; always nil. The reducer accepts `.progress(runId:fraction:)` for the day one does |
| `answering` | answer text is streaming to the screen (silent) — not `speaking` | text and voice turns |
| `connectivity` | `live · reconnecting` (run waiting for the network, Mac transport reconnecting) `· paused` (app left the foreground / run suspended) | cloud runs, Mac tasks |
| `mic` | `availability off/preparing/live`, `level` 0…1, `active` | iPhone capture; see below |
| `speech` | same shape for playback | on-device neural voice; see below |
| `intent`, `intensity`, `segment`, `intentSource` | optional expression the **model** declared for the answer segment being shown (text turn) or spoken (voice turn): `neutral curious focused explaining encouraging comforting playful celebrating apologetic cautious uncertain` | model-declared; measured per model, see below |
| `confidence` | reliability of the intent | **nil** (not measured per model with enough evidence to publish a number) |
| `event` / `detail` | why the cue was emitted: `turnStarted phaseChanged userSpeechStarted/Ended segmentStarted toolStarted/Succeeded/Failed approvalRequested/Resolved speechStarted/Ended interrupted cancelled failed completed reconnecting resumed modelSwitched level snapshot`; `detail` = failure code, interruption cause, tool operation or "approved/declined" | always |

### Levels: "no signal" is not "silence"
`level == nil` means there is no measurable signal (microphone open but nothing attends to it, microphone/speech not live, a source that cannot be metered); `0` is measured silence. Microphone `level` is reported only while `phase == .listening` (the capture also runs while the assistant speaks; its level then belongs to the assistant's own voice, not to the person). Scales are shared constants (`CompanionLevel`): microphone `(dB + 55) / 45`, playback `(dB + 50) / 44`, clamped to 0…1. Level cues are throttled to ≥ 1/30 s and ≥ 0.02 change.

## Runtime truth
- `preparing` until audio actually flows; `listening` only with a live microphone (a level callback is itself proof of audio).
- `awaitingApproval` is never `working`: approve → `thinking` until the tool really starts → `working`; decline → `thinking`. A voice-layer confirmation (memory, calendar draft) is also `awaitingApproval`.
- `speaking` only while the first audio of this turn has played and playback has not ended. Speech goes dark **at once** when playback is cut (barge-in, stop, route change, failure) and everything the turn delivers afterwards is dropped.
- `completed` is released once, after the run completed **and** (voice turns) the voice session went idle for the same turn, i.e. after the audio ended. `failed` carries the runner's code (`context_too_large`, `provider_error`, …). `interrupted` (cause: `user_speech`, `system_audio`, `route_change`, `background`) vs `cancelled` (`user_stop`, `superseded`, `expired`).
- A run's late events, replays after a reconnect (per-run sequence guard) and events of a finished turn never act twice. Runs of other conversations (when the UI says which conversation is on screen: `CompanionVoiceSignal.focus`) never move the character.
- The runner's own guard events (`fabricated_claim`, `skipped_tool`, `unsupported_figures`) and a model's malformed/repeated tool call are not tool failures; real execution failures, missing permissions and declined approvals are.
- Outcomes stay until the next activity or about 1.2 s (`settle`), then `idle`.

### Expression never contradicts the facts
`intent` is re-evaluated against the facts on every cue: `celebrating` needs a completed run with no failed / permission-blocked / declined tool; `playful` is blocked after any such failure; `failed`, `cancelled`, `interrupted` and every phase in which nothing is being answered are neutral; while `awaitingApproval` only `cautious` / `focused` survive. Spoken turns follow the **speech clock** (the chunk being played), text turns the generation clock. Expression is transient: nothing is persisted, no history is kept, nothing describes the person.

## Where semantic intent comes from (tone protocol)
No keywords, no extra model call, never from reasoning text. The runner appends one optional instruction to the system prompt (`ToneProtocol.instruction`, `RunnerConfig.semanticCues`, default on): a model may start a segment of **its own reply** with `[tone:comforting]` (optionally `[tone:comforting:high]`), only from the ten intents, describing how the reply sounds, never the person's state; ordinary replies carry no tag. `ToneTagFilter` (streaming, tolerant of bracket/space/case variants and of tags split over deltas) strips the tags from everything the person sees, hears or stores and the runner publishes each one as a **transient** `companion.segment` event (never persisted, no durability hooks). Unknown or malformed declarations are removed and mean neutral. A model that writes nothing yields neutral — the character then uses runtime state alone.

## Availability today
| Signal | Status |
| --- | --- |
| Microphone availability / level / voice activity | available on the iPhone (capture stages, tap level, the end-of-turn timer's debounced activity). Not on the watch. |
| Transcribing | available (`VoiceSession.finalizing`) |
| Thinking / working / approvals / outcomes (local, cloud, Mac) | available |
| Operation category | available (fixed tables) |
| Speaking + playback level | available for the on-device neural voice (level from the mixer tap, chunk position derived from what has fully played). The system voice (macOS/watch `SpeechOutput`) reports phases only: `speech.level == nil`. |
| Interruption / cancellation cause | available for barge-in, stop button, route change, system audio interruption; every other replacement counts as `superseded` |
| Stream reconnection | available: cloud runs (`awaitingNetwork`), Mac transport (`reconnecting`), replays ignored |
| Model switching | available: `modelSwitched` when the provider changes inside a run; a new run is a new turn |
| Progress | **unavailable** |
| Semantic intent — managed cloud model, on-device model | model-declared; numbers below |
| Semantic intent — Mac tasks | **unavailable** (the Mac agent does not use the tone protocol; Claude Code / Codex / ACP backends cannot be instructed): cues carry runtime state only |
| Confidence | **unavailable** (nil) |
| Legacy `voiceEmotion` / `speechEmphasis` on iOS | stay `.neutral` / 0.35; the keyword inference that used to feed the macOS path and the neural voice's cheerful/calm reference choice was removed |

MEASURED_AVAILABILITY

## Feeding it
- Voice: `AppModel.companion` (set in `iTalkApp`) receives `CompanionNote`s from the places where things really happen; `AppModel.session`'s `didSet` reports phase/turn changes, the hub translates them (`CompanionVoiceTranslator`).
- Agent runs: `AgentPlatform.observe` forwards every bus event with its turn id.
- Mac tasks: `RemoteCompanionBridge(taskId:)` turns each `RemoteEvent` (and the transport's reconnecting/connected) into the same inputs; deterministic run and conversation ids per task; replays by sequence are dropped. Wire-up in `RemoteDeviceCenter.watch` and `CompanionVoiceSignal.focus(conversation: bridge.conversationId)` while a task is on screen are described in WORK_COORDINATION.md.

## Tests
`swift test` in `Packages/AgentRuntime` (reducer sequencing, voice interruption, TTS/mic amplitude and throttling, tool success/failure, approval waiting, stream reconnection, model switching, tone filter incl. arbitrary chunking, real runner + scripted model, translator), `Packages/AssistantCore` (splitter chunk offsets, no keyword emotion), `Packages/RemoteAgent` (bridge). Real-model measurement: `tools/companion-eval` + `CompanionCueEvalTests` (`docs/measurements/companion-cues-2026-10-31.json`).
