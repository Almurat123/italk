# iTalk agent platform (2026-10-27)

One agent for every model, local or cloud.

- **Shared:** one Skill/Tool registry, one permission authority and one execution journal.
- **Independent:** models, skills, tools, permissions and execution are separate layers.
- **Status:** built and installed on the iPhone 16 Pro Max (iOS 27.2). Real-device verification is the user's (list at the end).

## Layers

| Layer | Where | What |
|---|---|---|
| Models | `ModelProvider`: `MLXModelProvider` (local Qwen3.5), `CloudGatewayProvider` (paid gateway `/v1/generate`) | Propose text and tool calls only. Switched with `runner.use(_:)`; running conversations keep their state. |
| Skills | `SkillCatalog` (AgentRuntime) plus `AppleSkills`, `WebSkill`, `MemoryTools.skill` | The **catalog** (id, name, one-line summary of every skill) is always in the system prompt for every model. `read_skill` returns instructions, tool schemas and live permission status, with no authorization and no side effects. `load_skill` makes the tools callable. Calling a tool of an unloaded skill loads it implicitly. No keyword routing, no deterministic routes, no model-size gating. |
| Tools | `ToolRegistry`: 74 tools in the app (64 Apple, 6 web, 2 memory, 2 core), each a real Swift executor | Strict argument validation. Structured JSON results and a one-line summary. `dataClass` is general, personal or sensitive. `permission` is one of: readOnly, lowRiskAction (journaled, no card), confirmBeforeAction (approval card bound to the exact arguments), restricted. |
| Permissions | `PermissionGate` + `ApplePermissionAuthority` + `CapabilitySettings` | Checked **live before every execution**: the iTalk switch first, then the system authorization. `notDetermined` shows the system prompt; reads never prompt. A denial returns a structured result and a `permissionRecovery` card (Settings › iTalk, the iTalk switch, or "not possible" for restricted/unsupported). HealthKit read status is `unknownByDesign`: the call proceeds and "no data" is explained as possibly "not allowed". |
| Execution | `AgentRunner` + `ExecutionJournal` | Stable execution id `runId/callId`, persisted before the side effect. Reconcile after a crash, never blind retry. A timeout is recorded as `outcomeUnknown`. The same action again in the same conversation within 30 minutes returns the earlier result (`alreadyDone`) instead of repeating it, including after a model switch. Side effects run **detached** from the model step, so a barge-in, Stop or model switch never aborts them halfway. |
| Sessions | `AgentPlatform` (iOS) | A run belongs to its conversation. Several conversations run at once; local GPU steps are serialized by `GenerationLane`, cloud steps run in parallel. Switching conversations, opening other screens or leaving the app never cancels; only an explicit Stop does. Every final answer is written to its own conversation via the run `tag`, even if nobody is waiting. Interrupted runs resume after relaunch. `awaitingNetwork` runs resume when the network returns. |

## Cloud models share the registry

`server/src/provider.mjs` `generate()` and the `server/src/server.mjs` `/v1/generate` route:

- The gateway relays messages and tool **schemas** to the upstream model, for both the Chat Completions and Responses protocols.
- It streams back deltas, **complete** tool calls, usage and the finish reason.
- Credit is reserved before dispatch and settled from real usage, as for `/v1/turns`.
- Health text needs `cloudHealth`.
- The gateway never executes tools.
- On the device, tool results marked `personal` or `sensitive` are replaced by a placeholder for cloud models unless the person enabled `cloudPersonalData` / `cloudHealthData` (both off by default). The run itself keeps the real result.

## Web: search, browse, extract, cite

`AgentRuntime/WebTools.swift`, `WebText.swift`. This is not Spotlight and needs no cloud model.

- **Search:** `web_search` goes through a provider chain, mainland first: Bing (cn.bing.com, then www.bing.com), Baidu, then DuckDuckGo. It remembers the last provider that worked. A self-hosted `SearXNGSearch` is optional.
- **Reading:** `open_webpage` (HTML, PDF, text), `read_page_section`, `find_in_page`, `list_page_links`, `follow_link`. JavaScript pages fall back to a non-persistent, offscreen `WKWebView` (`WebKitPageRenderer`).
- **Citations:** stable source numbers `[n]` per process, plus a citations card.
- **Protection against malicious pages:**
  - Hidden elements, comments, scripts, styles and zero-width/bidi characters are removed before the model sees text.
  - Results are framed as untrusted data, and the skill tells the model to ignore and report embedded instructions.
  - SSRF guard: only public http(s); no loopback, private, link-local or `.local` hosts; redirects checked.
  - Ephemeral session; cookies are in memory and for search engines only; size caps.

## Apple capability catalog (`Packages/AppleSkills`)

32 skills in the app (29 Apple capabilities plus web, memory and core) with 74 registered tools. Every advertised tool has an executor (checked by the `everyAdvertisedToolHasAnExecutorAndEveryToolIsInASkill` test).

| Skill | Tools | Framework |
|---|---|---|
| Calendar | calendar_list_events, calendar_create_event ✓, calendar_delete_event ✓ | EventKit |
| Reminders | reminders_list, create_reminder ✓, reminders_complete | EventKit |
| Alarms and timers | alarm_set, timer_start, alarm_list, alarm_cancel | AlarmKit |
| Notifications | notification_schedule, notification_list, notification_cancel | UserNotifications |
| Health | health_query (11 metrics), health_sleep, health_workouts | HealthKit (read only) |
| Apple Watch | watch_status | WatchConnectivity |
| Location | location_current (about 100 m precision by default) | CoreLocation + MapKit reverse geocoding |
| Maps | maps_search, maps_route (ETA), maps_open (Apple Maps / Amap / Baidu Maps) | MapKit |
| Weather | weather_forecast (current, daily, air quality) | Open-Meteo |
| Contacts | contacts_search, contacts_create ✓ | Contacts |
| Communication | message_compose, mail_compose (you tap Send), phone_call ✓ | MessageUI, tel/facetime |
| Photos | photos_search, photos_save, vision_analyze_image | Photos + Vision |
| Camera | camera_take_photo (then on-device recognition) | UIImagePicker + Vision |
| Vision | vision_analyze_image: OCR (Chinese/English), labels, barcodes, faces | Vision |
| Files | files_list, files_read, files_write ✓, files_import, files_share, files_delete ✓ (recoverable) | Documents (visible in the Files app) |
| PDF | pdf_read, pdf_search, pdf_create | PDFKit / CoreText |
| Audio | audio_transcribe | SpeechAnalyzer (on device) |
| Music | music_play, music_control, music_now_playing | MediaPlayer |
| Home | home_list, home_control, home_control_secure ✓, home_run_scene ✓ | HomeKit (needs the capability, see limits) |
| Device | device_status, motion_activity, screen_brightness, flashlight, network_status | UIKit, CoreMotion, AVFoundation, Network |
| Bluetooth | bluetooth_scan | CoreBluetooth |
| NFC | nfc_read_tag | CoreNFC (needs the capability) |
| Clipboard | clipboard_read, clipboard_write | UIPasteboard |
| Other apps | app_open (27 apps, including search and scan entry points where public), open_link ✓ | URL schemes / universal links |
| Shortcuts | shortcut_run ✓ | shortcuts:// |
| Translation | translate_text | Translation (installed languages) |
| Text analysis | text_analyze | NaturalLanguage |
| Conversations | conversations_search | iTalk's own database |
| Widgets | widgets_refresh | WidgetKit |
| Web | 6 tools | above |
| Memory | memory_save ✓, memory_search | the user-approved archive |

✓ = confirmation card before execution.

**Apple does not expose these to third-party apps.** They are documented in `AppleSkills.unsupported` and told to the model:

- Sending SMS/iMessage automatically; reading messages or call history.
- Reading WeChat or other apps' data, or acting inside them (payments, orders).
- Existing Clock alarms.
- Wi-Fi, Bluetooth, cellular and airplane toggles, system volume, Focus (these are possible only through a shortcut you build yourself).
- Listing shortcuts or reading their results.
- Other apps' notifications and Screen Time.
- Transit, bank and access cards; Apple Pay.
- Spotlight content of other apps.
- Watch faces.
- Managing classic Bluetooth pairings.
- Indefinite background microphone use.

## Background, voice and Live Activity

**Background voice:**

- `UIBackgroundModes = audio`. Pulling down Notification Center or Control Center (scene inactive) changes nothing; this used to cancel everything.
- Home, app switch or lock keeps an active voice session listening and speaking.
- On-device model steps pause in the background (iOS forbids GPU work there) and continue on return.
- A turn committed while locked waits for the app to come back. Cloud steps continue while iOS keeps the app alive.

**Live Activity:**

- `AgentActivityAttributes` / `AgentLiveActivity` show the real state: listening, thinking, working (tool line), speaking, waiting for you, paused.
- A Live Activity never keeps the agent alive.
- Stale activities from a previous process are ended at launch.

**Voices:**

- 小晴 (zf_001) and 小悦 (zf_003) are the recommended defaults and come in the base package (253 MB).
- 8 more voices are separate verified packs of about 0.5 MB each that share the weights: 小甜, 小雅, 小雨, 小禾, 阿伦, 阿哲, 阿宁, 阿川.
- Each pack can be downloaded, previewed, switched, updated (on a manifest version change) and deleted.
- All 10 were synthesized on the Mac with no clipping, about 0.6 s per sentence. Naturalness is for the user to judge.
- No Apple system voice fallback.
- "Advanced" voices (Qwen3-TTS, evaluated on the Mac: `build/tts-samples/qwen3tts-*`) are **not** available on iPhone yet.

## Model Center data (`ModelCenterCatalog.cards()`)

Each card carries:

- Developer, logo asset name, parameters, quantization, advertised versus iTalk context, download and memory size, license.
- **Advertised** capabilities kept separate from **in-iTalk status** (verified, implemented-but-unverified, not implemented, each with a note).
- Performance numbers that each name where they were measured. Mac numbers are labelled as such.

## The twelve safeguards

| # | Safeguard | Implementation |
|---|---|---|
| 1 | Shared context across models | Context is built from the conversation database for whichever provider runs the next step. The runner keeps messages and tool results across `use(_:)`. |
| 2 | Unreliable small-model tool calling | Strict validation, with the schema returned on error. Implicit skill loading. Unknown tool → skill hint. Bounded steps (12) and tool calls (24). The approval card is the final gate. |
| 3 | Switching models mid-run | `runner.use` affects only the next step. Journal deduplication prevents repeats. Test: `sameSideEffectIsNotRepeatedAcrossRunsOrModels`. |
| 4 | Permission recovery | Live `PermissionGate`, structured result, recovery card. Tests: `deniedPermissionReturnsRecoveryInsteadOfRunning`, `permissionAuthorityRespectsITalkSwitches`. |
| 5 | Confirming risky operations | `confirmBeforeAction` card bound to the run, component, revision, expiry and idempotency key. A destructive set of tools is enforced by test. |
| 6 | Malicious web content | Hidden-text stripping, untrusted framing, SSRF guard (tests `extractorDropsHiddenInjection…`, `webSafetyBlocks…`). |
| 7 | Verified model capabilities | Model cards keep "advertised" and "in iTalk" apart. |
| 8 | Memory contention | One GPU lane. Only the selected voice loaded. Model unload on memory warning, never mid-answer. |
| 9 | Cross-provider tool compatibility | One `ToolSpec` becomes strict JSON Schema for cloud (`CloudGatewayProvider.schema`) and the tool-call text format for MLX. |
| 10 | Voice interruption during tool execution | Side effects run detached and are journaled (test `cancellingTheRunNeverAbortsASideEffectHalfway`). |
| 11 | Accurate tool result cards | The summary comes from the executor's real result (e.g. "已创建并验证…"). Citations and permission cards come from real outputs. |
| 12 | Versioned downloads with rollback | The hash-verified multi-source manifest (v2026-10-27.2), per-artifact versions, `updateAvailable` for voice packs. Installs are staged in `partial/` and swapped in only after verification. |

## Tests (Mac)

- **AgentRuntime:** 71 of 73 pass. The 2 failures (`attachmentsArePersisted…`, `onlyRecentImagesReach…`) are this environment's sandbox refusing atomic writes with `.completeFileProtection` in the temporary folder (EPERM). Not a code change.
- **AppleSkills:** 10 of 10 pass. Real Vision OCR read "杭州西湖 营业时间 9:00"; a PDF was created, read and searched; NaturalLanguage, file sandboxing and catalog integrity checked.
- **Gateway:** 20 of 20 pass, including the `/v1/generate` relay for both protocols, consent and billing.
- **Live network (`ITALK_LIVE_WEB=1`):** Bing and DuckDuckGo returned results; swift.org, Wikipedia and W3C pages were opened, read and followed; Open-Meteo returned weather and air quality. The Mac exits through a US IP, so mainland reachability (cn.bing.com, Baidu, Open-Meteo, hf-mirror) still has to be confirmed on the iPhone with the VPN off.

## Needs the person / real-device verification

- **HomeKit and NFC:** add the capabilities in Xcode › Signing & Capabilities (an account must be signed in; the command line has none), then build with `ITALK_EXTENDED_CAPABILITIES=1 node scripts/generate-project.mjs`. Until then both report "not enabled" (no crash).
- **On the iPhone:**
  - Every permission prompt and the denied → Settings recovery path.
  - Calendar, reminders and alarms creation, plus duplicate protection.
  - Camera, NFC, Bluetooth, music and Translation (downloaded languages).
  - Web search with the VPN off.
  - Locking or switching apps during voice; Notification Center pull-down.
  - The Live Activity.
  - Approval cards in chat.
  - Two conversations answering at once.
  - Voice-pack download from hf-mirror.


## 2026-10-27 — end-to-end acceptance fixes (reasoning trace, truthful permissions, working actions)

### What was actually wrong (from the run files on the phone, not guesses)

| Symptom | Root cause | Fix |
|---|---|---|
| "已成功设置闹钟" but no alarm | The 2B model never called a tool and invented the result. Calls to a tool that was not declared in the request were also silently dropped by MLX. | `load_skill` now carries the whole catalog as an enum (the format small models are trained on). Undeclared-tool calls are handed to the runner, which loads the owning skill. A final answer that claims an action while no tool ran is discarded and corrected (`ActionClaims`). |
| Web search showed a category form, content vanished | `ask_user_choice` was always offered; the model used it for a search question and looped. Completed cards were removed from the UI. | The form tool is gone. The system prompt says what needs fresh information must be searched, not asked about. Steps are persistent trace items and are never removed. |
| Endless "正在思考" | One spinner for every state. | The turn shows the real state: reasoning stream, tool running, waiting for you, permission needed, then the answer. |
| HealthKit never asked / unclear switches | The model never reached the tool, and there were two sets of switches (old Scope grants and new capability switches). | One permission center (设置 › 工具与权限): iTalk switch + live iOS state per capability, 请求权限 / 前往系统设置. An unanswerable HealthKit status now leads to a request, never to silent success. A health read with no data says so and links to Settings. |
| Alarm "failed without a useful result" | Any non-ToolFailure error became "工具执行失败". | Errors keep their domain, code and reason. Alarms are read back from AlarmKit to verify. The alarm Live Activity widget is registered. |
| Tool loops | Same search repeated until the step budget killed the task. | Third identical call, or running low on steps, withholds tools: the model must answer from what it has. |
| Declining a confirmation showed "参数不正确" | The decline path was labelled like a validation error. | Declined steps say "你没有允许这项操作，没有执行". |

### Reasoning and execution trace

- `GenerationEvent.reasoningDelta` carries the model's own reasoning. `ReasoningTextParser` splits `<think>` content from the answer across chunk boundaries (Qwen3.5 thinking mode opens the block inside the prompt).
- It is persisted per step in `RunSnapshot.reasoning`, shown live, kept in the trace, never spoken, never fed back to the model, and never created for a model that does not provide it. Spoken turns never reason.
- The cloud gateway relays `reasoning_content` / reasoning-summary deltas only when the upstream sends them (`MODEL_REASONING_SUMMARY=true` asks the Responses API for summaries).
- `AgentTrace` (per turn): reasoning blocks interleaved with execution steps, timing and state. Finished work collapses to "思考与执行 · 2分35秒" (or "执行 · 12秒" when no reasoning existed) and expands at any time. It stays open while something needs the person.
- Persistence: Application Support/iTalk/traces.json (bounded). After a relaunch, interrupted work shows as stopped; resumed runs continue their clock.
- Several conversations: traces are keyed by turn; model switches and resumes keep the trace.

### Real-model behavior (Qwen3.5-2B on the Mac, tools stubbed except web)

- Alarm, steps, weather, calendar: load_skill → tool → answer, every time in 4 prompts. With thinking on, the same prompts produced real reasoning ("用户要求设置一个早上10点的闹钟。我需要调用 alarms 技能…") and still called the right tools.
- News and price questions: searched and answered with cited items in 4 of 4 runs after the loop breaker; before it, 2 of 3 looped until failure.
- Limits: the 0.8B model is unreliable at tool use; the 2B sometimes needs an extra load step; answer quality follows the search snippets.
