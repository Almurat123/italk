# Conversation, context, vision and suggestions — contract for Codex (2026-10-26)

Claude owns data and behaviour; Codex owns how it looks. Keep the existing iOS 26 visual language; nothing here asks for a new design.

## Audit (M0) — what was missing
- No conversation database: chat lived in RAM (80 turns, images RAM-only). "History" was a flat Q/A list (≤100, 30 days) inside one AES JSON blob rewritten on every save. No titles, pin, archive, rename or conversation-level search.
- `LocalModelCenter` kept its own 8-message history: a duplicate, unpersisted state.
- No context-window management at all (the runner received whatever history it was given).
- Images always went to cloud: the model was loaded with the text-only `LLMModelFactory`, and `AppModel`/`AssistantView` required cloud consent for any image. The pinned Qwen3.5 0.8B/2B artifacts **do** contain the vision tower (144/288 `vision_tower.blocks` tensors, `Qwen3VLProcessor`).
- New conversations showed a fabricated assistant bubble 「嗨，我在。」.

## Storage (M1)
- SQLite via the system library (`AgentRuntime/ConversationStore.swift`); chosen over SwiftData for FTS5 trigram search (works for Chinese), explicit transactions and package-level tests. iOS data protection (`completeUntilFirstUserAuthentication`, attachments `complete`), excluded from backup.
- Tables: conversations, messages (structured `parts`, strict `seq` order, status), attachments (authorized local JPEG copies + SHA-256), summaries (versioned), runs, FTS index.
- History consent: persisted only when 「保存非敏感对话历史」 (`.history`) is on; otherwise an in-memory store for the session. Health-related turns are **session-only** unless health memory is allowed: usable as context, excluded from search, removed at next launch.
- Soft delete → restorable (undo) → purged after 30 days. Pending (streaming) messages are never final; on relaunch they become `cancelled`.
- Old flat history is imported once into conversations (titles from the question). Imported items currently show today's date as last activity — known limitation.

## Context (M1)
`AgentRuntime/ContextManager.swift`. Per turn: budget = 80 % of the model window − 512 output − 700 tools. If over budget: summarize the oldest unsummarized messages outside the last 4 user turns and before any pending tool/approval, ≤3 bounded chunks per turn. Deterministic fact extraction keeps user corrections, requirements, negations, quantities with units, dates and tool records verbatim (token-capped, priority-ordered); an optional model narrative (2B only, 20 s timeout) is advisory. Summary failure → deterministic facts; save failure → previous valid summary. Messages are never deleted. Only images from the last 2 user turns are re-sent; older ones become text references. Tests: 59 pass, including the retention test (name, allergy + negation, flight 10月30日下午3点45分, the corrected budget 「两千元，不是三千元」 survive compaction of 66 messages).

## Vision (M2)
`MLXModelProvider(vision: true)` loads through `VLMModelFactory`; images go per message as local file URLs; the processor caps at 768×768 px (≈ 576 image tokens). Photo prep (existing): ≤1280 px, orientation applied, JPEG re-encode, metadata stripped. Image turns use the local model when installed — no cloud dialog, no subscription.
Measured on an M3 Pro Mac, Release, 1600×1200 synthetic image (red circle + blue square), one model per process:

| | 0.8B | 2B |
|---|---|---|
| load | 0.9 s | 1.5 s |
| first token (558-token prompt) | 0.40 s | 0.92 s |
| peak MLX memory | 1.86 GB | 2.86 GB |
| answer | correct colours and shapes | correct, detailed |

2B echoed the prompt for one specific phrasing (「图片里有哪些颜色的什么形状？用一句中文回答。」) at temperature 0.2 — a model quirk, recorded. **Not yet run on the iPhone.**

## Swift types Codex binds to
- `ConversationLibrary` (environment object, iOS): `conversations`, `archived`, `lastDeleted`, `currentId`, `historyEnabled`, `lastContextStatus`, `grouped(now:) -> [(ConversationGroup, [Conversation])]`, `search(_:) async -> [ConversationSearchHit]`, `rename`, `setPinned`, `setArchived`, `delete` (soft), `undoDelete`.
- `Conversation` (id, title, titleSource, createdAt, lastActivityAt, pinned, archived, deletedAt, lastModelId, messageCount, preview, hasUnfinishedRun).
- `ConversationGroup` order: 置顶, 今天, 昨天, 7 天内, 30 天内, 更早.
- `ConversationMessage` + `MessagePart` (`text`, `image(attachmentId:)`, `tool(...)`, `card(componentId:)`), `MessageStatus` (`pending` must render as in-progress, never as done).
- `AppModel.openConversation(_:)`, `AppModel.newConversation()`, `AppModel.localVisionAvailable`.
- `PromptSuggestion` from `SuggestionEngine.suggestions(recent:)`: `.send(text)` or `.openConversation(id)`; kinds unfinishedTask / continueConversation / timeOfDay / starter. Show nothing if the list is empty.
- `ContextStatus` (window, budget, estimated tokens, summary version, compacted flag, build ms) — developer diagnostics only.
- `ModelCapabilities`: `ProviderCapabilities.visionInput` plus `LocalChatEngine.supportsVision`.

## What Claude changed in Codex-owned views (functional minimum; restyle freely)
- `AssistantView`: fake greeting bubble replaced by suggestion buttons (`.bordered` capsules); send skips the cloud-image dialog when `localVisionAvailable`; sidebar callback is `selectConversation(UUID)`.
- `ConversationSidebar`: rows come from `ConversationLibrary` (grouped sections, search hits, collapsible 已归档, 撤销 after delete); long-press menu 重命名 / 置顶 / 归档 / 删除. Same row view as before.
- `iTalkApp`: creates `ConversationLibrary`, injects it, imports old history once.

## Accessibility identifiers
`history.conversation.<id>`, `history.hit.<id>`, `history.archived`, `history.undoDelete`, `assistant.suggestion.<kind>`.

## Not done yet
Voice turn-taking (M4), neural TTS (M5), expressive/custom voices (M6), multi-model memory coordinator beyond the existing advisor (M7), on-device verification of everything above (M8), conversation export UI, cloud-provider context path.
