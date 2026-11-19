# Local-first model architecture

Status 2026-10-26. Supersedes the cloud-first assumptions below. Source of truth for ADR-004 in `voice-assistant-research-design.md` stays valid (local ASR/TTS); this document adds local **LLM** inference as the free foundation.

## 1. Cloud-first assumptions found in the repository (and what replaces them)

| Where | Assumption | Replacement |
| --- | --- | --- |
| `apps/Shared/AppModel.swift` ~L210 | Any question that is not a local tool needs `.cloudAI` grant, otherwise the answer is "需要云端模型". A free user has no language model at all. | Router picks a local `ModelProvider`; cloud is an explicit, consented, entitled option (`ModelRouter`). |
| `apps/Shared/GatewayClient.swift`, `server/src/server.mjs` | The only model path is `POST /v1/turns`, single message, no tools, no history. | Gateway becomes one `ModelProvider` (`kind: .cloudGateway`). Not built yet; see §7. |
| `README.md` "Gateway setup still required" | Onboarding is gateway URL + token. | Onboarding = download a local model. Gateway/account only for paid features. |
| Settings (`SettingsView.swift`) | Endpoint/token are consumer settings. | Move to developer settings (Codex-owned UI). |
| `AssistantCore/Policy.swift` scopes `.cloudAI/.cloudHealth` | Good as consent gates; keep. | Reused by `ModelPolicy`. |

Nothing in the existing UI was modified by this work.

## 2. Unified provider contract (`Packages/AgentRuntime/Sources/AgentRuntime/Provider.swift`)

`ModelProvider`: `descriptor` (capabilities), `prepare(progress:)`, `generate(_:) -> AsyncThrowingStream<GenerationEvent>`, `unload()`. Events: `textDelta`, complete `toolCall`, `usage` (prompt/completion tokens, first-token latency, tokens/s), `completed`. Cancelling the consuming task stops generation. Capabilities: context window, streaming, `toolCalling` (none/constrained/native), structured output, `maxAutonomy`, `worksOffline`, `sendsContentOffDevice`, resident memory.

Implementations:

| Provider | Where | Status |
| --- | --- | --- |
| `MLXModelProvider` (downloaded Qwen3.5) | `Packages/LocalInference` | Builds for macOS and generic iOS (deployment target 26). Real tokens streamed through `AgentRunner` on a Mac. Not run on an iPhone. |
| `AppleFoundationProvider` | `AgentRuntime` (guarded by `canImport(FoundationModels)`, `@available(iOS 26)`) | Compiles. Never executed (needs Apple Intelligence eligibility). Chat-only, no tool bridge. |
| Cloud gateway provider | – | Not implemented. Contract proven only with `ScriptedModelProvider` (not a real model). |

`AgentRunner` takes any provider and can swap it (`use(_:)`) without touching conversation, tools, cards or events.

### Routing rules (`ModelRouter`, tested)
- Default is local. A free user is never routed to cloud.
- Cloud requires: user turned it on **and** accepted disclosure **and** server-verified entitlement; health content additionally needs separate health consent.
- If local is unusable (thermal, memory) and cloud exists, the result is `needsUserChoice(.localUnavailableOfferCloud)` — nothing is sent.
- Expired subscription → local again; local history/memory untouched.

## 3. Engine decision: MLX Swift LM (`ml-explore/mlx-swift-lm` 3.32.3)

| | MLX Swift LM | llama.cpp (`llama.swiftui`) | Pocket AI Lab / local-ai |
| --- | --- | --- | --- |
| What it is | Swift package, MIT | C++ engine, XCFramework built by script; README of the example says nothing on Metal, streaming, min iOS | Apps (MIT), 4 and 9 commits; Pocket AI Lab bundles MLX+llama.cpp+CoreML+AFM, `local-ai` uses MLX |
| Qwen3.5 support | `Qwen35.swift` in MLXLLM; mlx-community 4-bit repos exist | GGUF builds exist (third-party); not tested here | `local-ai` claims 80/55/26 tok/s (0.8B/2B/4B) on iPhone 17 Pro — author claim, not verified |
| Integration | SwiftPM, `Generation` async stream incl. native tool-call parsing, JSON-schema/EBNF guided generation (`MLXGuidedGeneration`) | C API wrapper written by us | reference only |
| Risk | Young 3.x line; default-on trait pulls iOS-27-only FoundationModels bridge | Hand-maintained Swift binding, tool parsing by us | tiny repos |

**Chosen: MLX Swift LM**, single engine. Reasons: native Swift concurrency and streaming, built-in tool-call parsing, grammar-guided generation available for weak-model tool use, Qwen3.5 architecture shipped, small hybrid KV (see §4). **Not adopted yet:** llama.cpp (revisit if MLX memory behaviour on 6 GB phones fails; one reference app reports mmap-backed engines tolerate tighter budgets — unverified here).

Compatibility traps found and handled:
1. mlx-swift-lm's `FoundationModelsIntegration` trait is **default-on** and requires the 27.0 SDK types. `LocalInference/Package.swift` sets `traits: []`. Without this the iOS 26 baseline silently breaks.
2. `MLXHuggingFace` macros require macro trust (`-skipMacroValidation`). Not used; `TransformersTokenizer.swift` is a hand-written bridge, and downloading is done by our own hash-verifying `ModelStore`. No network code from the engine is linked.
3. Only an iOS 27 SDK is installed here. A generic-iOS build with deployment target 26 succeeds; that is evidence, not proof of behaviour on iOS 26 devices.
4. `swift test` cannot run MLX (no Metal library). Use `xcodebuild test` (Metal toolchain installed).

## 4. Models

Licenses checked against Hugging Face metadata on 2026-10-26: base `Qwen/Qwen3.5-{0.8B,2B,4B}` = apache-2.0; `mlx-community/Qwen3.5-*-MLX-4bit` conversions = apache-2.0 (artifact license checked separately; the conversion repos contain no LICENSE file of their own, so retain the base license text in-app before shipping).

| Model | 4-bit size | Peak MLX memory (Mac) | Role |
| --- | --- | --- | --- |
| 0.8B | 625 MB | ~1.0 GB | chat only (`maxAutonomy = chatOnly`) |
| 2B | 1.72 GB | ~1.76 GB | starting candidate, `restrictedTools` |
| 4B | 3.05 GB | not measured | not in catalog: not downloaded, hashes unpinned |

Qwen3.5 is hybrid: 6 of 24 layers use full attention, so KV cache is 12,288 bytes/token (4096 tokens ≈ 50 MB). This is derived from `config.json`, not measured.

`ModelCatalog` pins every file to an HF commit and SHA-256 (0.8B, 2B). Catalog autonomy defaults are tested to be below `fullAgent`.

## 5. Measured vs. not measured

**Measured (Apple M3 Pro Mac, Release build, 2026-10-26; raw JSON in `docs/benchmarks/`). These are NOT iPhone numbers.**

| | 0.8B | 2B |
| --- | --- | --- |
| Load from disk | 2.5 s | 4.9 s |
| First token, cold (first call) | 0.32 s | 3.3 s |
| First token, warm (n=3) | 0.05 / 0.19 / 0.19 s | 0.06 / 0.06 / 0.10 s |
| Tokens/s, warm (n=3) | 79.5 / 53.1 / 66.1 | 29.5 / 60.5 / 26.2 |
| Peak / active MLX memory | 1000 / 461 MB | 1761 / 1101 MB |
| Cancel → GPU idle | 8.7 ms, 0 stale deltas | 6.9 ms, 0 stale deltas |
| Calculator tool used by the runner (n=5, default prompt) | 0/5 (model answered itself; 3/5 final answers correct) | 0/5 (3/5 correct answers) |
| Calculator call with explicit tool instruction (n=1 probe) | no call (1 rejected `incompleteOutput`) | valid `calculate {"expression":"12*(3+4)"}` |
| Reminder run reached the approval card (n=5) | 1/5 | 4/5 |
| Side effects without approval | 0 | 0 |

Small samples, one machine, throughput noisy. 0.8B output contained LaTeX (`$$ … \times`): speech text must be sanitised before TTS. These numbers justify the conservative `chatOnly` default for 0.8B and a *restricted* default for 2B; they do not justify raising autonomy.

**Not measured at all:** anything on an iPhone — memory pressure, thermals, battery, Low Power Mode behaviour, background/suspension, airplane-mode conversation, 4B, Chinese answer quality beyond one sample, Apple Foundation Models. The only physical device Xcode lists (an iPhone running 27.2) is offline, so real-device acceptance is **blocked**.

## 6. Resource management (`DeviceResources.swift`, `ModelStore.swift`; unit-tested with synthetic profiles)
- `ResourceAdvisor.canRun`: shrinks context before refusing; thermal ≥ serious caps context and autonomy; critical refuses; Low Power Mode caps; no-GPU warns.
- `ResourceAdvisor.canDownload`: free disk ≥ 1.1× size + 500 MB.
- `ResidencyPlanner`: LRU unload plan so ASR/LLM/TTS are not resident together when over budget.
- `ModelStore`: staged download (resume data kept on URLError), size + SHA-256 per file, atomic install, re-verify, remove, clear partial downloads; manifest survives relaunch.
- **Not implemented:** reading the live profile (`os_proc_available_memory`, thermal notifications, `MTLCreateSystemDefaultDevice`), background `URLSession`, UI progress binding, memory-warning handler.

## 7. Weak-model agent policy
- `maxAutonomy` gates what the runner exposes: `chatOnly` → no tools passed to the model; `restrictedTools` → read-only and approval-gated tools only.
- Fixed phrases (time/date) are answered by `SkillCatalog.deterministicRoute` with no model call.
- Qwen `<tool_call>` markup is stripped by `ToolCallTextParser` so it can never reach the screen or TTS; unterminated calls are discarded.
- Every proposal still passes strict argument validation, capability grant, and approval.
- Next lever (unbuilt): `MLXGuidedGeneration` grammar-constrained tool JSON.

## 8. Cloud provider (deferred by priority)
Existing `server/` is single-shot. To become a provider it needs a `/v1/agent/steps` endpoint accepting messages + tool specs and streaming `delta | tool_call | usage | completed` NDJSON, plus a Swift `GatewayModelProvider`. Entitlement, metering, StoreKit work stays as already built in `server/`; none of it was changed here.
