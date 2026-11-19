# Interactive UI contract (v1)

Defined in `UI.swift`. The model never emits SwiftUI or code. Codex renders only these cases; unknown cases must be shown as a plain `errorRecovery`-style fallback, never executed.

## Components (`UIComponent.Content`)
`information`, `progress`, `toolActivity`, `searchResult`, `choice`, `confirmation`, `healthSummary`, `dateTimePicker`, `form`, `taskProgress`, `approval`, `followUp`, `errorRecovery` (kind names: `InformationCard` … `ErrorRecoveryCard`). Each component: `schemaVersion`, stable `id`, `runId`, `revision`, `content`, `actions[]`, optional `expiresAt`.

Runtime currently *creates* only `approval` (for confirm-before-action tools) and `choice` (model tool `ask_user_choice`, 2–6 unique options). The other cases are defined and validated but nothing produces them yet.

## Action (`UIAction`) and response (`UIActionResponse`)
Action: `id`, `kind` (select/approve/decline/submit/retry/dismiss), `label`, `requires` (`none` < `userTap` < `deviceAuth`).
Response from SwiftUI: `schemaVersion`, `runId`, `componentId`, `componentRevision`, `actionId`, `idempotencyKey` (client-generated UUID per tap), `authorization` (what the UI actually obtained), `payload`.
Payloads: choice select → `{"optionId": "<id>"}`; approval approve/decline → none; form submit → field map; dateTimePicker → `{"date": ISO-8601}` within bounds; followUp select → `{"suggestion": "<text>"}`.

Call `AgentRunner.submit(_:)`. It throws `ActionRejection`: `unsupportedSchema, wrongRun, unknownComponent, staleRevision, componentClosed, expired, unknownAction, duplicate, unauthorized, invalidPayload, noPendingInteraction` (or `RunnerError.unknownRun`). On success the same run resumes from its checkpoint. A rejected action changes nothing. Render rejections quietly (e.g. disable the card on `expired`/`componentClosed`/`duplicate`).

Approval cards expire after `RunnerConfig.approvalTTL` (300 s). `AgentRunner.resume(runId)` moves an expired pending run to `expired`.

## What the card is allowed to authorise
An approval binds to the exact tool call recorded in the run (arguments are the validated ones). The UI cannot change arguments. `create_reminder` text shown on the card comes from `AgentTool.describe`, not from model prose.

## Rendering state source
Render from `RunSnapshot.components` (status `open/completed/removed`) for restore after relaunch, and from `ui.component.*` events for live updates.
