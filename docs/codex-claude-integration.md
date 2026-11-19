# Codex ↔ Claude integration contract

## Ownership
- **Codex:** everything under `apps/` (SwiftUI, navigation, animation, cards, Watch UI), `scripts/generate-project.mjs`, `iTalk.xcodeproj`.
- **Claude:** `Packages/AgentRuntime`, `Packages/LocalInference`, and the docs listed here. `server/` is currently being edited by Codex (emotional speech relay, see `WORK_COORDINATION.md`); Claude will not touch it until the gateway-provider endpoint is agreed. Nothing under `apps/` or the Xcode project was modified by this work. The repository has no commits; all of it is untracked, so nothing was committed either.
- **Shared, change only by agreeing here:** `AgentEvent`, `RunState`, `UIComponent`, `UIAction(Response)`, `ModelProvider`/`ProviderCapabilities`, `ToolSpec`. Bump `schemaVersion` on any breaking change.

## Wiring done (2026-10-26)
- `scripts/generate-project.mjs`: `Packages/AgentRuntime` (product `AgentRuntime`) and `Packages/LocalInference` (product `MLXProvider`) are linked to the **iTalk iPhone target only**. Project regenerated; `iTalk` scheme builds for iOS Simulator (arm64) with the Watch targets embedded and not linking MLX.
- `apps/Shared/LocalChat.swift`: `LocalChatEngine` protocol (the only thing Shared/Watch code sees).
- `apps/iOS/LocalModelCenter.swift`: download → verify → load → unload, live `DeviceProfile`, runs chat through `AgentRunner`, streams cumulative sanitised text.
- `apps/iOS/LocalModelSection.swift`: Settings section (picker, size, state, real byte progress, cancel, delete, last-answer metrics).
- Hooks in Codex files: `AppModel.localChat` + local branch in `execute` for plain `.conversation` (no images), `cancel()` forwards, `cancel(clear:)` resets history; `iTalkApp` injects the center; `SettingsView` shows `LocalModelSection` on iOS.
- Routing choice: plain conversation prefers the installed local model; research, images and the existing deterministic intents (time, health, calendar, reminders, memory) are unchanged. If no model is installed the old cloud path applies, with a message that also points to the local download.

## What the UI calls
```swift
let store = try FileRunStore(directory: appSupport/"runs")
let models = try ModelStore(root: appSupport/"models")
// after install: MLXModelProvider(artifact: ModelCatalog.qwen35_2b_4bit, directory: await models.directory(for:)!)
let runner = AgentRunner(provider: provider, tools: ToolRegistry([...]), store: store, granted: { grantedCapabilities })
let runId = try await runner.start(conversationId: id, text: userText)   // voice and text identical
for await e in await runner.bus.subscribe(runId: runId) { ... }          // stream text, progress, cards
try await runner.submit(UIActionResponse(...))                           // card taps
await runner.cancel(runId); await runner.resume(runId)                   // stop / relaunch / network back
```
- Streaming text: `model.output.delta` (`content`). Speak only these, never tool or activity events; sanitise Markdown/LaTeX first.
- Model state UI: `provider.prepare(progress:)` reports `PreparationState` (`checkingResources → loading → ready/failed`); show it, loading takes seconds (measured 2.5–4.9 s on a Mac).
- Download UI: `ModelStore.install(_, onState:)` → `DownloadState`.
- Mic button truth: audio state is not owned by the runtime yet; keep ASR/TTS state in your layer and send final text to `start`.

## Rules
1. SwiftUI never mutates `RunSnapshot`; send actions only.
2. One active run per conversation (`RunnerError.conversationBusy`); cancel first to replace.
3. Free local mode must make zero network calls except model download. Gate any `ModelPolicy.cloud*` flag behind the consent UI.
4. Tell Claude before changing a shared type. Tests that must stay green: `swift test` in `Packages/AgentRuntime` (34).

## Open integration items
Not done: a user-visible "prefer cloud" switch; showing model loading/\"thinking\" state in the chat (only Settings shows load state); thermal/memory-pressure notifications beyond the memory-warning unload; replacing `Confirmation`/`ActionDraft` flows with approval cards; Watch; any on-device run.
