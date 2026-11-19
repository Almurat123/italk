# V1 acceptance matrix (local-first)

Legend: **pass** = executed and passed; **partial** = something real ran, gaps stated; **mock** = deterministic fake only; **not run**; **blocked**.

## Mandatory real-iPhone validation (items 1–12)
| # | Check | Status | Evidence / blocker |
|---|---|---|---|
| 1 | Download approved model | partial | Passed in the app UI on an iOS 26.5 simulator: Settings → Qwen3.5 0.8B → download with live byte progress → SHA-256 verified → state 已安装 (650 MB). Not on a phone. 2B not downloaded in-app. |
| 2 | Load without exhausting memory | partial | Mac peak 1.0 GB (0.8B), 1.76 GB (2B). iPhone not measured. |
| 3 | Conversation in airplane mode | blocked | no reachable iPhone (Xcode lists one offline). Engine itself performs no network I/O (tokenizer + weights from disk). |
| 4 | Real tokens into SwiftUI | partial | App wiring done and builds (simulator + generic device). Real tokens stream through `AgentRunner` on a Mac. **In the app they have not been shown**: MLX crashes on the iOS Simulator (the same test passes on macOS and crashes on the simulator), so the app now refuses on simulator. Needs a physical iPhone. |
| 5 | Chinese voice question fully on-device | not run | ASR/TTS not part of this work yet. |
| 6 | Validated local tool | partial | calculator/time/reminder tools run under validation; with a real model only the 2B probe produced a valid call (n=1). |
| 7 | Native card + real action | partial | approval/choice cards and action validation tested with scripted model; real model reached approval 4/5 (2B). No SwiftUI rendering. |
| 8 | Cancel without stale output | partial | real MLX: GPU idle 7–9 ms after cancel, 0 stale deltas (Mac). Scripted test also passes. |
| 9 | Suspension/termination recovery | partial | snapshot + side-effect reconciliation tested via `FileRunStore` simulated restart; no real iOS suspension. |
| 10 | Load time, TTFT, tok/s, memory, thermal | partial | measured on Mac only (`docs/benchmarks/`); thermal/battery not measured. |
| 11 | No cloud requests in free mode | not run | no network capture performed. Router tests prove logic only. |
| 12 | Cloud provider reuses interface | mock | `ScriptedModelProvider(kind: .cloudGateway)` through the same runner and router; no real gateway provider. |

## Automated tests (executed 2026-10-26)
- `Packages/AgentRuntime`: `swift test` → 34 tests pass (state machine, parser, validation, routing, runner flows, cards, crash reconcile, event replay/redaction, resources, model store, catalog).
- `Packages/LocalInference`: `xcodebuild test` Release, env-gated real-model test passes for 0.8B and 2B. `xcodebuild build -destination generic/platform=iOS` succeeds.
- Existing `server/` tests (11) passed when run at start; `swift test` for `AssistantCore` (Codex-owned): 11 tests pass at 2026-10-26 16:00.

## Original scenarios A–L
| | Status |
|---|---|
| A voice conversation | not run (no ASR/TTS integration) |
| B text conversation | partial (runner only) |
| C multi-step run | mock + partial real (calculator loop with scripted model; 2B single probe) |
| D choice card | mock |
| E reminders | mock (fake store; EventKit adapter not written) |
| F HealthKit | not run (no health tool written) |
| G interruption | partial (simulated restart) |
| H two devices | not run (ownership/lease not implemented) |
| I subscription | not run (server pre-existing, untouched) |
| J abuse limits | not run for new code |
| K privacy | partial (event redaction test only) |
| L accessibility/degraded | not run |

## Known gaps in what exists
Memory consolidation, proactive suggestions, idle-time tasks, HealthKit tools, EventKit reminder store, device-ownership for Watch, grammar-constrained tool output, gateway provider, background task scheduling, Live Activities, `run.started/suspended`, `tool.progress`, `ui.component.updated`, skill-discovery latency metrics, UI wiring.

## App integration run (2026-10-26, iOS 26.5 simulator, own throwaway device)
- Settings section renders in the existing Settings form; model picker, size, state, download, byte progress: observed working.
- Found and fixed: `os_proc_available_memory()` is 0 on the simulator and was read as "no memory" (refused load). Now 0 = unknown.
- Found: MLX generation crashes the process on the iOS Simulator (reproduced in a bare test target with no app code). Guarded in `LocalModelCenter`; the app shows 「iOS 模拟器不支持本地模型的 GPU 推理，请在真机上运行。」 and does not crash.
- Not observed: any on-device (phone) generation, streaming into the chat bubble, history across turns, cancel from the UI, memory-warning unload.

## Mainland China download (2026-10-26)
| Check | Status | Evidence |
|---|---|---|
| Multi-source manifest, failover, Range resume across sources, corrupt-source rejection, storage check, relaunch resume, dev import | pass (unit) | 10 stub-network tests in `DeviceTests.swift`; 43/43 AgentRuntime tests pass |
| hf-mirror / ModelScope serve identical bytes | partial | Mainland iPhone, VPN off: both reachable, smallest file identical. Weights not yet confirmed |
| Download without VPN on a mainland network | pending user test | First attempt failed (empty source plan, fixed). New build installed 2026-10-26 |
| Offline use after install | not run on device | Engine does no network I/O; device test pending (user is testing manually) |
