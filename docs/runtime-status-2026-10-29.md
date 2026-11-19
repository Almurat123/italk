# Runtime status — 2026-10-29 (Claude runtime session)

Written when the session's usage limit was reached. "Verified" means observed running; nothing below was verified on the iPhone
(the phone has been unreachable since 20:08, after the UI session's last install).

## Landed and verified on the Mac (tests / builds)
- AgentRuntime: 104 tests pass (adds memory store, approval policy + runner integration). AssistantCore: 44 pass (pre-roll buffer). NeuralSpeech: 11 pass
  (+1 real MOSS streaming test with `ITALK_MOSS_DIR`). Generic iOS Debug build of the app is green.
- UI-facing centers (Skills, Model Center incl. MOSS, Account, Remote, Memory), Codex-style approvals (scopes, untrusted-content rule, audit log): see
  WORK_COORDINATION.md. The UI session has adopted them.

## Landed, NOT verified on a device
- Capture rewrite (`LocalSpeechInput.swift`): mic first + 90 s pre-roll, recognizer attaches later. Simulator probe: mic running 8–28 ms after the request, first
  100 ms buffer at ~110–130 ms; the recognizer is unavailable in the simulator, so the end-to-end "no lost words" claim is unproven. Run `-captureProbe` on the phone.
- MOSS-TTS-Nano engine + streaming playback (`SpeechPlayback.swift`, `NeuralVoice.swift`, `Packages/NeuralSpeech`). iPhone speed/memory/thermal unmeasured; the app
  calibrates itself (RTF > 0.9 → falls back to Kokoro). Run `-ttsProbe` (stage the 14 manifest files in Documents/import/moss-tts-nano-100m-coreml first).
  **Superseded 2026-10-31:** Kokoro and the calibration-based fallback were removed (that fallback is what silently disabled MOSS on the owner's phone); MOSS is the only engine and the speed number only sizes the playback buffer. See `docs/voice-architecture.md`.
- The Release build the UI session installed at ~20:07 already contains the capture rewrite (untested on the phone).

## Voice evaluation (Mac; Apple zh-CN SpeechTranscriber round trip, 10 sentences — a proxy, not a MOS)
| engine | mean CER | notes |
| --- | --- | --- |
| Kokoro v1.0 zh (speech-swift, zf_xiaoxiao / zf_xiaoyi) | 0.207 / 0.250 | garbles words; English unusable |
| MOSS-TTS-Nano default | 0.076 | English perfect; ~80–110 ms to first audio; RTF 0.38 on Mac CPU (GPU/ANE no faster) |
| Qwen3-TTS 0.6B CustomVoice (vivian / serena) | 0.016 / 0.001 | best quality, too slow for phones (premium tier for Mac/cloud) |
Not measured: the app's own Kokoro (FluidAudio zh ANE variant) on the Mac. Voices for MOSS are reference-code sets built from Qwen3-TTS recordings
(`tools/voices`), four voices × neutral/cheerful/calm. A listening pack for the user has NOT been produced yet.

## DeepSeek (live checks, official API, `deepseek-flash`)
- Thinking + tool calls work: `reasoning_content` streams, tool call arrives, usage includes `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` and
  `reasoning_tokens`. Latency from this network 2.6–5.4 s per small call. Models listed: `deepseek-flash`, `deepseek-v4-pro`.
- With thinking on and tools present, history WITHOUT `reasoning_content` (omitted or empty string) was accepted (HTTP 200), contrary to the docs' "400".
  The gateway is stricter than the API (`server/src/server.mjs:139`, `provider.mjs:127` throw `reasoning_context_unavailable`) and would break switching from a
  local model to DeepSeek mid-conversation with reasoning on. First server fix: send `reasoning_content: ""` instead of failing; bill cache-hit tokens at the cache price.

## Agent benchmark (`Packages/LocalInference/Tests/MLXProviderTests/AgentBenchTests.swift`, runner `tools/agent-bench/bench.sh`)
25 scenarios × N samples with deterministic stubs (reads, modifies, external, web, no-tool chat, ambiguity, honesty, permission denial, prompt injection).
Smoke (Qwen3.5-2B, 1 sample, 4 scenarios): 1/4 — it answered "what time is it" and a calculation without calling a tool and set 07:00 instead of 07:30.
Full baselines for 2B and 0.8B were started in the background; results land in the scratchpad as `bench-Qwen3.5-*-think0.log/.json`. No improvement work done yet.

## Not started
Smart Turn end-of-turn model, AEC/barge-in verification, memory auto-extraction + retrieval into context, context-compaction changes, iCloud sync (needs the iCloud
capability enabled in Xcode), accounts/subscription server rewrite, remote desktop agent + pairing protocol, listening pack, device performance report.

## Next steps, in order
1. Phone reachable → announce "installing now" to the UI session → Release build with `OTHER_SWIFT_FLAGS='$(inherited) -DITALK_PROBES'` → stage MOSS files → `-ttsProbe`, `-captureProbe` → pull the JSON from Documents.
2. Server: relax the reasoning-context check, record cache tokens; then the account/subscription work.
3. Read the agent baselines and fix the biggest failure classes (tool-skipping, argument errors) with measured before/after.
4. Smart Turn + AEC/barge-in on device; memory extraction/retrieval; remote agent.
