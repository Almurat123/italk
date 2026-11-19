# Agent event protocol (v1)

Defined in `Packages/AgentRuntime/Sources/AgentRuntime/Events.swift`. Same envelope for local and cloud providers. Wire format: JSON, camelCase keys, ISO-8601 dates, keys sorted.

## Envelope
`schemaVersion` (1), `eventId` (UUID), `runId`, `conversationId`, `stepId`, `parentId?`, `sequence` (per-run, 1-based, gapless), `timestamp`, `type`, `visibility`, `payload`.

`visibility`:
- `activity` – safe progress; UI and logs.
- `content` – the person's text and tool output; UI only. `AgentEvent.redacted()` replaces the payload with `redacted`.
- `diagnostic` – developer only (reserved; none emitted yet).

## Types emitted today
`run.created`, `run.state` (every state change, with from/to/reason), `run.resumed`, `run.completed`, `run.failed`, `run.cancelled`, `model.request.started`, `model.output.delta` (content), `model.request.completed`, `skill.discovered`, `skill.loaded`, `tool.proposed`, `tool.arguments.validated`, `tool.started`, `tool.completed` (content summary), `tool.failed` (activity code), `approval.requested`, `approval.resolved`, `ui.component.created` (content, carries the card), `ui.component.completed`, `ui.component.removed`, `usage.updated`.

**Transient (never stored, no durability hooks, still ordered with a sequence number on the live stream):** `companion.segment` — where a segment of the model's answer starts and the tone the model declared for it (`ToneSegment`, see `docs/companion-cue-contract.md`). Produced by `AgentEventBus.publish(…, persist: false)`; consumers that replay from the store never see it. `model.output.delta` text is already free of tone tags, and so is the stored message. `tool.progress` carries `ToolActivity` (now with `operation`, the tool's category).

Declared but **not emitted yet**: `run.started`, `run.suspended`, `model.*` status beyond above, `ui.component.updated`, `speech.*` (audio layer is not built).

## Run states
`created, queued, planning, running, awaitingTool, awaitingApproval, suspended, awaitingNetwork, awaitingForeground, resuming, completed, failed, cancelled, expired`. Transitions are enforced by `RunState.canTransition`; illegal ones are ignored, not applied. `awaitingApproval` is used for both approval and choice cards ("waiting for the person").

## Delivery guarantees
- Events are persisted (append-only JSONL in `FileRunStore`) **before** subscribers see them. Subscribers get a bounded buffer (newest 256); a slow UI drops old events and can replay with `RunStore.events(runId:after:)`.
- `AgentEventBus.ingest` rejects duplicates (`eventId`) and stale sequence numbers (≤ last) and unknown schema versions.
- Provider streams are not resumable. After a crash the run continues from its last snapshot (new model request), never from a byte offset.

## Example (typed question, one tool, final answer)
`run.created` → `run.state created→running` → `model.request.started` → `model.output.delta`* → `usage.updated` → `model.request.completed` → `tool.proposed` → `tool.arguments.validated` → `run.state running→awaitingTool` → `tool.started` → `tool.completed` → `run.state awaitingTool→running` → `model.request.started` → `model.output.delta`* → … → `run.state running→completed` → `run.completed`.
Approval variant inserts `ui.component.created`, `run.state →awaitingApproval`, `approval.requested`, then after the tap `approval.resolved`, `ui.component.completed`, `run.state →running`.

Fixtures: the executable examples are the tests in `Tests/AgentRuntimeTests/RuntimeTests.swift` (replay with `ScriptedModelProvider`).
