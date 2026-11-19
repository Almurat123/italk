import Foundation
import Observation
import AVFoundation
#if os(iOS)
import UIKit
import AgentRuntime
#endif
import OSLog
import AssistantCore

@MainActor @Observable final class AppModel {
    var session = VoiceSession() {
        didSet {
            guard companion != nil, oldValue.phase != session.phase || oldValue.generation != session.generation else { return }
            companion?(.session(old: oldValue, new: session, conversation: conversationBackend?.currentId, spoken: companionSpoken))
        }
    }
    /// The iPhone's companion hub listens here (nil elsewhere). Notifications only; see `CompanionNote`.
    @ObservationIgnored var companion: ((CompanionNote) -> Void)?
    /// The answer of the current turn is going to be read aloud (so its expression follows the spoken position, not the text).
    private var companionSpoken: Bool { speakCurrentTurn && voice.isActive && archive.preferences.speakResponses }
    /// Per queued speech chunk: its length in spoken characters and where its source starts in the plain answer text.
    @ObservationIgnored private var companionChunks: [(length: Int, start: Int)] = []
    @ObservationIgnored private var companionPlayedChunks = -1
    var archive = PrivateArchive()
    var message: String?
    var memoryProposal: String?
    var confirmation: Confirmation?
    var actionDraft: ActionDraft?
    var account: GatewayAccount?
    var reviewing: [ConsolidationProposal] = []
    var isSaving = false
    var sourceNote: String?
    var researchSources: [ResearchSource] = []
    var conversation: [ConversationTurn] = []
    var audioLevel: Double = 0
    var speechBeat = 0
    var speechLevel = 0.0
    var voiceEmotion = VoiceEmotion.neutral
    var speechEmphasis = 0.35
    var readingMessage = false
    var dictationDraft: String?
    /// The microphone is already capturing, but language assets or the recognizer are still loading (text will catch up;
    /// nothing said is lost). The UI can show "正在准备语音识别…".
    var recognizerPreparing = false
    /// On-device chat engine (iOS only). Plain conversation uses it before any cloud path; set by the app entry point.
    @ObservationIgnored var localChat: (any LocalChatEngine)?
    /// Conversation database (iOS). Every turn is recorded here; local models build their context from it.
    @ObservationIgnored var conversationBackend: (any ConversationBackend)?
    @ObservationIgnored private var turnModel: [UUID: String] = [:]
    /// Images can be understood on this device without cloud consent or a subscription.
    var localVisionAvailable: Bool { localChat.map { !$0.usesCloud && $0.isAvailable && $0.supportsVision } ?? false }
    @ObservationIgnored private var captureIntent = CaptureIntent()
    @ObservationIgnored private var speakCurrentTurn = true
    @ObservationIgnored private var approvedImageTurn: UUID?
    @ObservationIgnored private var disk: SecureArchive?
    @ObservationIgnored private var storageReady = false
    @ObservationIgnored private let speechInput = SpeechInput()
    @ObservationIgnored private let speechOutput = SpeechOutput()
    #if os(iOS)
    @ObservationIgnored private let cloudSpeech = CloudSpeechPlayback()
    #endif
    @ObservationIgnored private let health = HealthService()
    @ObservationIgnored private let calendar = CalendarService()
    @ObservationIgnored let gateway = GatewayClient()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var accountRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var endpointTask: Task<Void, Never>?
    @ObservationIgnored private var lastSpeech = Date.now
    /// Adaptive end-of-turn detection (AssistantCore.TurnDetector). Pause habits learned this session carry to the next turn.
    @ObservationIgnored private var turn = TurnDetector()
    @ObservationIgnored private var learnedPauses: [TimeInterval] = []
    @ObservationIgnored private var lastPlaybackEnded = Date.distantPast
    /// The one authoritative voice-conversation state (multi-turn). UI binds to `voice.state`.
    var voice = VoiceSessionCoordinator()
    /// Per-turn timestamps for latency diagnosis (written to Documents/voice-metrics.jsonl; numbers only, no text).
    @ObservationIgnored private var timeline = VoiceTimeline()
    @ObservationIgnored private var finalizeDone = false
    /// Neural voice (iOS: MOSS-TTS-Nano). Speaks stable sentences while the answer is still being generated.
    @ObservationIgnored var neuralSpeech: (any StreamingSpeechEngine)?
    @ObservationIgnored private var splitter = StreamingSpeechSplitter()
    @ObservationIgnored private var stepText = ""           // the current model step's cumulative text as last fed to the splitter
    @ObservationIgnored private var streamingTurn: UUID?
    @ObservationIgnored private var observations: [NSObjectProtocol] = []
    // Full-duplex voice session: one echo-cancelled capture runs for the whole session (also while the assistant speaks).
    @ObservationIgnored private var duplexRun: UUID?
    @ObservationIgnored private var fullTranscript = ""
    @ObservationIgnored private var segmenter = TranscriptSegmenter()
    /// Transcript length when the user's current utterance began (start of a barge-in turn).
    @ObservationIgnored private var onsetLength = 0
    @ObservationIgnored private var pendingTurnStart: Int?
    /// Spoken interruption is allowed: echo cancellation is active, or output goes to headphones.
    @ObservationIgnored private var bargeInEnabled = false
    @ObservationIgnored private let bargeIn = BargeInDetector()
    /// Everything sent to the voice for the current answer (echo reference for barge-in and the listening re-arm).
    @ObservationIgnored private var assistantSpeech = ""
    @ObservationIgnored private var releasedFirstPhrase = false
    /// App lifecycle hook (true = entered background, false = returning). Set by the iPhone app (agent platform).
    @ObservationIgnored var lifecycle: ((Bool) -> Void)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.italk.assistant", category: "latency")
    var grants: Set<Scope> { archive.preferences.grantSet }
    var token: String { String(data: KeychainStore.read("gateway-token") ?? Data(), encoding: .utf8) ?? "" }

    init() {
        do { let disk = try SecureArchive(); self.disk = disk; archive = try disk.load(); storageReady = true }
        catch { message = "私人数据无法打开，请解锁设备后重新启动。未覆盖已有数据。" }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo.map { dict in Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in (k as? String).flatMap { key in (v as? UInt).map { (key, $0) } } }) } ?? [:]
                Task { @MainActor in
                    guard let self, self.duplexRun != nil || [.listening, .speaking, .synthesizing].contains(self.session.phase) else { return }
                    self.handleAudioNotification(name, info: info)
                }
            })
        }
        #if os(iOS)
        // Leaving the app ends capture (no background listening); the session is paused, not lost.
        // Home, app switch or lock keeps an active voice session going (background audio mode: capture and playback
        // continue). On-device model steps pause until the app returns (GPU work is not allowed in the background).
        // Notification Center / Control Center only make the scene inactive and change nothing here.
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lifecycle?(true) }
        })
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lifecycle?(false) }
        })
        #endif
    }
    @discardableResult func persist() -> Bool {
        guard storageReady, let disk else { message = "私人存储暂不可用，未保存更改。"; return false }
        do { try disk.save(archive); return true } catch { message = "保存失败，请检查设备解锁状态和存储空间。"; return false }
    }
    func setGrant(_ scope: Scope, allowed: Bool) {
        if !allowed { cancel() }
        if [.cloudHealth, .cloudVoice].contains(scope) && allowed && !grants.contains(.cloudAI) { message = "请先开启并确认云端 AI 处理。"; return }
        archive.preferences.set(scope, allowed)
        if scope == .cloudAI && !allowed { archive.preferences.set(.research, false); archive.preferences.set(.cloudHealth, false); archive.preferences.set(.cloudVoice, false) }
        if scope == .memory && !allowed { memoryProposal = nil; confirmation = nil; reviewing = [] }
        persist()
    }
    func authorize(_ scope: Scope) async {
        do {
            if scope == .healthRead { try await health.authorize() }
            if scope == .calendar || scope == .reminders { try await calendar.authorize(reminders: scope == .reminders) }
            setGrant(scope, allowed: true)
        } catch { message = error.localizedDescription }
    }
    #if DEBUG
    /// Developer test harness only (a tunnel to a development gateway). Release builds have no way to point the app at another service.
    func configure(endpoint: String, token: String) throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw AppFailure.message("网关必须是无账号、无查询参数的 HTTPS 地址。") }
        accountRefreshGeneration &+= 1
        cancel()
        try KeychainStore.write(Data(token.utf8), account: "gateway-token")
        archive.preferences.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        archive.preferences.set(.cloudAI, false); archive.preferences.set(.cloudHealth, false); archive.preferences.set(.research, false)
        archive.preferences.set(.cloudVoice, false)
        account = nil; persist()
    }
    #endif
    /// What the central voice button does right now (Codex renders icon and label from this).
    var voiceControlAction: VoiceControlAction {
        switch session.phase {
        case .listening:
            return session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .pause : .submit
        case .preparing, .finalizing, .thinking, .synthesizing, .speaking, .confirming: return .stop
        case .idle: return voice.isActive ? .pause : .start
        case .failed, .interrupted: return .start
        }
    }
    func toggleVoice() {
        switch voiceControlAction {
        case .start: startListening()
        case .submit: finishListening()                 // explicit end of turn
        case .pause, .stop: pauseVoice()                // always stops everything; the next tap resumes
        }
    }
    /// Authoritative, synchronous stop: UI state, playback, TTS queue, LLM and microphone stop in this call; no callback of
    /// the stopped turn can re-arm listening (new generation + paused coordinator).
    func pauseVoice() {
        timeline.mark(.stop_button_tapped)
        let pending = operation
        companion?(.endCause("user_stop"))
        _ = voice.handle(.userPause)
        cancel()
        timeline.mark(.session_ui_stopped)
        message = "已暂停，点按麦克风继续。"
        var stopped = timeline; timeline = VoiceTimeline()
        Task { [weak self] in
            await pending?.value                          // returns once generation actually stopped
            stopped.mark(.inference_cancel_completed)
            self?.writeTimeline(stopped)
        }
    }
    /// Ends the continuous voice session (microphone off until the user starts again).
    func endVoiceSession() { companion?(.endCause("user_stop")); _ = voice.handle(.userStop); cancel() }

    /// Long-term memory exposed to the agent as tools. Saving always goes through the runner's confirmation card.
    func memoryAccess() -> (enabled: @MainActor () -> Bool, save: @MainActor (String) -> String?, search: @MainActor (String) -> [(id: String, text: String)]) {
        ({ [weak self] in self?.grants.contains(.memory) ?? false },
         { [weak self] content in
            guard let self, self.grants.contains(.memory), !content.isEmpty, content.count <= 2000 else { return nil }
            let sensitive = MandarinRouter.isPotentiallySensitive(content)
            guard !sensitive || self.grants.contains(.healthMemory) else { return nil }
            let record = MemoryRecord(content: content, sensitive: sensitive, sourceTurn: self.session.generation)
            self.archive.memories.append(record)
            guard self.persist() else { self.archive.memories.removeAll { $0.id == record.id }; return nil }
            return record.id.uuidString
         },
         { [weak self] query in
            guard let self else { return [] }
            let visible = self.archive.memories.filter { !$0.sensitive || self.grants.contains(.healthMemory) }
            let hits = query.isEmpty ? Array(visible.suffix(10)) : visible.filter { $0.content.contains(query) || query.contains($0.content.prefix(4)) }
            return hits.map { ($0.id.uuidString, $0.content) }
         })
    }

    /// The scene left the foreground. Only a hold-to-talk dictation is dropped (the finger is gone); the voice session and
    /// agent runs continue.
    func sceneLeftForeground() {
        if captureIntent.delivery == .dictation, session.phase == .listening || session.phase == .preparing { cancel() }
    }

    /// Conversation listening always runs inside a voice session that re-arms itself after each answer.
    /// Hold-to-talk dictation is a one-shot capture outside the session.
    func startListening(delivery: CaptureDelivery = .conversation, held: Bool = false) {
        if delivery == .conversation && !held { applyVoice(.start) }
        else { _ = voice.handle(.userStop); beginCapture(delivery: delivery, held: held) }
    }

    private func applyVoice(_ event: VoiceSessionCoordinator.Event) {
        if event == .start { neuralSpeech?.warmUp() }
        switch voice.handle(event) {
        case .startListening: beginCapture(delivery: .conversation, held: false)
        case .stopListening, .stopSpeaking:
            cancel()
            if case .paused(let reason) = voice.state { message = reason == .noSpeech ? "已暂停，点按麦克风继续。" : "语音已暂停，点按麦克风继续。" }
        case .commitTurn, .none: break
        }
    }

    private func handleAudioNotification(_ name: Notification.Name, info: [String: UInt]) {
        if name == AVAudioSession.routeChangeNotification {
            // Our own category switches (record ↔ playback) also post route changes; only real device changes matter.
            let reason = info[AVAudioSessionRouteChangeReasonKey].flatMap(AVAudioSession.RouteChangeReason.init) ?? .unknown
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            // The capture is bound to the old route: rebuild it. AirPods out while talking: stop the answer and listen.
            if voice.isActive && (session.phase == .listening || reason == .oldDeviceUnavailable) { companion?(.endCause("route_change")); cancel(); applyVoice(.start) }
            return
        }
        if name == AVAudioSession.interruptionNotification {
            let type = info[AVAudioSessionInterruptionTypeKey].flatMap(AVAudioSession.InterruptionType.init)
            if type == .began { companion?(.endCause("system_audio")); if voice.isActive { applyVoice(.interruptionBegan) } else { cancel() }; message = "通话或其他音频打断了语音，点按麦克风继续。" }
            return
        }
        companion?(.endCause("system_audio")); cancel(); _ = voice.handle(.userStop); message = "音频服务已重置，点按麦克风重新开始。"
    }

    private func beginCapture(delivery: CaptureDelivery, held: Bool) {
        let duplex = delivery == .conversation && !held
        if duplex, duplexRun != nil { listenOnRunningCapture(); return }      // the session's capture is already running
        cancel()
        companion?(.mic(.preparing))
        voiceEmotion = .neutral
        captureIntent = CaptureIntent(delivery: delivery, held: held)
        speakCurrentTurn = delivery == .conversation
        dictationDraft = nil
        message = nil; sourceNote = "普通话 · 设备端识别"
        let id = session.begin()
        let run = UUID()
        if duplex { duplexRun = run; fullTranscript = ""; segmenter = TranscriptSegmenter(); onsetLength = 0; assistantSpeech = "" }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.session.generation == id else { return }
                // The microphone starts at once and keeps everything (pre-roll); there is deliberately no wait before it. A
                // pause here (permission, previous capture teardown, echo tail) is exactly where the first words used to be lost.
                recognizerPreparing = false
                try await self.speechInput.start(duplex: duplex, onText: { [weak self] text in
                    guard let self else { return }
                    if duplex { if self.duplexRun == run { self.receiveDuplex(text) }; return }
                    guard self.session.generation == id else { return }
                    self.session.receiveTranscript(text, for: id)
                    self.turn.transcript(text, at: .now)
                    self.timeline.mark(.new_asr_partial)
                }, onActivity: { [weak self] in
                    guard let self else { return }
                    if duplex { if self.duplexRun == run { self.voiceActivity() }; return }
                    guard self.session.generation == id else { return }; self.lastSpeech = .now
                }, onError: { [weak self] error in
                    guard let self else { return }
                    if duplex { guard self.duplexRun == run else { return }; self.duplexRun = nil; self.fail(error, id: self.session.generation); return }
                    self.fail(error, id: id)
                }, onLevel: { [weak self] level in
                    guard let self, duplex ? self.duplexRun == run && self.session.phase == .listening : self.session.generation == id else { return }
                    self.audioLevel = level
                    self.companion?(.micLevel(level))
                }, onStage: { [weak self] stage in
                    guard let self, duplex ? self.duplexRun == run : self.session.generation == id else { return }
                    self.noteCaptureStage(stage)
                })
                guard self.session.generation == id, !Task.isCancelled else { return }
                if duplex {
                    self.bargeInEnabled = self.speechInput.echoCancelled || Self.headphoneRoute
                    self.timeline.echoCancellation = self.speechInput.echoCancelled
                }
                self.session.transition(.listening, for: id)
                self.markListenStarted()
                self.lastSpeech = .now
                if self.captureIntent.finishRequested { self.finishListening(); return }
                self.startEndpointTimer(id: id)
            } catch { self.fail(error, id: id) }
        }
    }

    /// Next turn on the session's running capture: no microphone restart, nothing the user already said is lost.
    private func listenOnRunningCapture() {
        stopAnswer(interrupted: false)
        captureIntent = CaptureIntent(delivery: .conversation, held: false)
        speakCurrentTurn = true; voiceEmotion = .neutral; message = nil
        let id = session.begin()
        // Speech that began just before the re-arm (or the interruption itself) belongs to this turn.
        let speaking = Date.now.timeIntervalSince(lastSpeech) < 0.5
        segmenter.beginTurn(at: pendingTurnStart ?? (speaking ? max(onsetLength, segmenter.offset) : fullTranscript.count))
        pendingTurnStart = nil
        session.transition(.listening, for: id)
        markListenStarted()
        startEndpointTimer(id: id)
        let text = segmenter.turnText(fullTranscript)
        if !text.isEmpty { session.receiveTranscript(text, for: id); turn.transcript(text, at: .now) }
    }

    /// Maps pipeline stages onto the voice timeline (device latency analysis) and the "preparing recognition" flag.
    private func noteCaptureStage(_ stage: CaptureStage) {
        switch stage {
        case .requested: timeline.mark(.capture_requested, overwrite: true)
        case .micRunning: timeline.mark(.mic_running, overwrite: true)
        case .firstBuffer(let frames):
            timeline.mark(.first_audio_buffer, overwrite: true); logger.info("first_audio_buffer frames=\(frames, privacy: .public)")
            companion?(.mic(.live))
        case .recognizerPreparing: recognizerPreparing = true
        case .recognizerReady: recognizerPreparing = false; timeline.mark(.recognizer_ready, overwrite: true)
        case .firstText: recognizerPreparing = false; timeline.mark(.first_text, overwrite: true)
        }
    }

    private func markListenStarted() {
        timeline.sessionId = voice.sessionId; timeline.turn = voice.turn
        timeline.route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue
        timeline.mark(.listen_started)
    }

    private static var headphoneRoute: Bool {
        let wearable: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { wearable.contains($0.portType) }
    }

    private func voiceActivity() {
        let now = Date.now
        // A new utterance starts after ≥0.8 s of silence; shorter dips belong to the same utterance.
        if now.timeIntervalSince(lastSpeech) > 0.8 { onsetLength = fullTranscript.count }
        lastSpeech = now
    }

    /// Continuous transcript of the voice session. Listening: the current turn's slice. Thinking/speaking: barge-in check.
    private func receiveDuplex(_ full: String) {
        fullTranscript = full
        let id = session.generation
        switch session.phase {
        case .listening:
            let text = segmenter.turnText(full)
            // Without echo cancellation the tail of our own answer can arrive after the re-arm: drop it, never answer it.
            if Date.now.timeIntervalSince(lastPlaybackEnded) < 2,
               bargeIn.evaluate(heard: text, assistantSpeech: assistantSpeech, voiceRecentlyActive: true) == .echo {
                segmenter.beginTurn(full: full); return
            }
            session.receiveTranscript(text, for: id)
            turn.transcript(text, at: .now)
            if !text.isEmpty { timeline.mark(.new_asr_partial) }
        case .thinking, .synthesizing, .speaking:
            guard voice.isActive && bargeInEnabled else { return }
            let heard = String(full.dropFirst(min(full.count, max(onsetLength, segmenter.offset))))
            let verdict = bargeIn.evaluate(heard: heard, assistantSpeech: assistantSpeech,
                                           voiceRecentlyActive: Date.now.timeIntervalSince(lastSpeech) < 0.6)
            if verdict == .interrupt { performBargeIn() }
        default: break
        }
    }

    /// The user spoke over the answer: stop audio and generation at once, keep only what was actually heard, and continue
    /// the same capture as the new turn (its first words are already in the transcript).
    private func performBargeIn() {
        timeline.mark(.user_barge_in_detected)
        logger.info("barge_in")
        companion?(.endCause("user_speech"))
        stopAnswer(interrupted: true)
        timeline.mark(.old_audio_stopped)
        flushTimeline()
        pendingTurnStart = max(onsetLength, segmenter.offset)
        applyVoice(.bargeIn)
    }

    /// Stops the current answer (LLM, TTS queue, playback, cloud audio) without touching the microphone.
    private func stopAnswer(interrupted: Bool) {
        companion?(.speechStopped(turn: session.generation, cause: interrupted ? "user_speech" : "superseded"))
        if let index = conversation.firstIndex(where: { $0.id == session.generation && $0.state == .pending }) {
            // An interrupted spoken answer keeps only what the user actually heard.
            let heard = streamingTurn == session.generation ? (neuralSpeech?.playedText ?? "") : ""
            if interrupted && !heard.isEmpty { conversation[index].answer = heard }
            conversation[index].state = .cancelled
            let turn = conversation[index]
            Task { await conversationBackend?.recordAssistant(turnId: turn.id, text: turn.answer, final: false, failed: false, modelId: nil, sessionOnly: false) }
        }
        operation?.cancel(); operation = nil; endpointTask?.cancel(); gateway.cancel(); speechOutput.stop(); localChat?.cancel()
        neuralSpeech?.stop(); streamingTurn = nil
        #if os(iOS)
        cloudSpeech.stop()
        #endif
        speechLevel = 0; speechEmphasis = 0.35
    }
    private func startEndpointTimer(id: UUID) {
        var config = TurnDetector.Config()
        config.maxTurn = 15 * 60                      // people dictate for minutes; only silence (or the finger) ends a turn
        turn = TurnDetector(config: config, start: .now, learnedPauses: learnedPauses)
        endpointTask = Task { [weak self] in
            var voiced = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.session.generation == id, self.session.phase == .listening else { return }
                let now = Date.now
                // Voice is "on" while activity keeps arriving; 300 ms without it is a pause (not yet the end of the turn).
                let active = now.timeIntervalSince(self.lastSpeech) < 0.3
                if active != voiced {
                    self.turn.voice(active: active, at: active ? now : self.lastSpeech); voiced = active
                    self.companion?(.micVoice(active))
                    _ = self.voice.handle(active ? .speechDetected : .endOfTurnCandidate)
                }
                let decision = self.turn.decide(at: now)
                if self.captureIntent.held {
                    if decision == .maxDuration { self.finishListening(); return }    // hold-to-talk: the finger decides
                    continue
                }
                switch decision {
                case .listening: continue
                case .endOfTurn(let reason):
                    self.logger.info("turn_end \(reason, privacy: .public)")
                    self.learnedPauses = self.turn.observedPauses
                    if let quiet = self.turn.silenceStartedAt { self.timeline.mark(.last_user_speech, at: Self.uptime(quiet)) }
                    self.finishListening(); return
                case .noSpeech:
                    if self.voice.isActive { self.session.cancel(); self.applyVoice(.noSpeech) } else { self.finishListening() }
                    return
                case .maxDuration:
                    self.finishListening(); return
                }
            }
        }
    }
    func finishListening() {
        let id = session.generation
        guard session.transition(.finalizing, for: id) else { return }
        endpointTask?.cancel()
        audioLevel = 0
        let duplex = duplexRun != nil && captureIntent.delivery == .conversation && !captureIntent.held
        timeline.mark(.last_user_speech, at: Self.uptime(lastSpeech))
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // Duplex: the capture keeps running; the next turn starts after this text. Otherwise bounded finalization
                // (waiting for the analyzer's full finalization was a major part of the perceived end-of-turn delay).
                if duplex { self.segmenter.beginTurn(full: self.fullTranscript) }
                else { await self.finishCapture(timeout: .milliseconds(self.captureIntent.delivery == .dictation ? 1200 : 400)); self.companion?(.mic(.off)) }
                guard self.session.generation == id, !Task.isCancelled else { return }
                let text = self.session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    if self.voice.isActive { self.session.cancel(); self.applyVoice(.noSpeech) }
                    else { self.cancel(); self.message = "没有听清，点按后可以再说一次。" }
                    return
                }
                if self.captureIntent.delivery == .conversation {
                    _ = self.voice.handle(.turnCommitted); self.timeline.mark(.turn_committed)
                    self.assistantSpeech = ""; self.releasedFirstPhrase = false
                }
                if self.captureIntent.delivery == .dictation {
                    self.dictationDraft = text
                    self.session.cancel()
                    return
                }
                self.appendTurn(.init(id: id, question: text))
                self.session.transition(.thinking, for: id)
                try await self.execute(text, id: id)
            } catch { self.fail(error, id: id) }
        }
    }
    private func finishCapture(timeout: Duration) async {
        let input = speechInput
        finalizeDone = false
        let finishing = Task { @MainActor [weak self] in _ = try? await input.finish(); self?.finalizeDone = true }
        // A recognizer that is still loading (first use: language assets) gets the time it needs; the audio is already safe.
        let deadline = ContinuousClock.now + (input.recognizerReady ? timeout : .seconds(12))
        while !finalizeDone && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if !finalizeDone { finishing.cancel(); await input.cancel() }
    }
    func releaseDictation() {
        captureIntent.release()
        if session.phase == .listening { finishListening() }
    }
    func warmDictation() {
        #if os(iOS)
        speechInput.warmDictationAssets()
        #endif
    }
    func submit(_ text: String, images: [ImageAttachment] = [], imagesApproved: Bool = false, speak: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !images.isEmpty), text.count <= 3000, images.count <= 3, images.allSatisfy({ $0.data.count <= 900_000 }) else { return }
        if !images.isEmpty && !localVisionAvailable && (!imagesApproved || !grants.contains(.cloudAI)) { message = "请先开启云端 AI，并确认发送所选图片。"; return }
        cancel(); message = nil; sourceNote = nil
        voiceEmotion = .neutral
        speakCurrentTurn = speak
        let id = session.begin()
        approvedImageTurn = imagesApproved ? id : nil
        appendTurn(.init(id: id, question: text, images: images))
        session.transition(.listening, for: id); session.receiveTranscript(text, for: id)
        session.transition(.finalizing, for: id); session.transition(.thinking, for: id)
        operation = Task { [weak self] in
            guard let self else { return }
            await self.speechInput.cancel()
            do { try Task.checkCancellation(); try await self.execute(text, id: id) }
            catch { self.fail(error, id: id) }
        }
    }
    private func execute(_ text: String, id: UUID) async throws {
        guard session.generation == id else { throw CancellationError() }
        let images = conversation.first(where: { $0.id == id })?.images ?? []
        // Record the user turn first: the agent reads its context (history, images) from the conversation database.
        let sessionOnly = MandarinRouter.isPotentiallySensitive(text) && !grants.contains(.healthMemory)
        await conversationBackend?.recordUser(turnId: id, text: text, images: images.map(\.data), sessionOnly: sessionOnly,
                                              inputMode: speakCurrentTurn ? "voice" : "text")
        #if os(iOS)
        // iPhone: every request goes to the agent (local or cloud model). No keyword routing: the model reads the skill
        // catalog and chooses tools; permissions and confirmations are enforced by the runner.
        guard let engine = localChat, engine.isAvailable else {
            throw AppFailure.message("需要一个语言模型：请在 设置 › 本地模型 下载，或在模型中心选择云端模型。")
        }
        guard images.isEmpty || engine.supportsVision else { throw AppFailure.message("当前模型不能理解图片，请换用支持图片的本地模型。") }
        guard let conversationId = conversationBackend?.currentId else { throw AppFailure.message("对话未能保存，请重试。") }
        sourceNote = engine.usesCloud ? "云端模型 · \(engine.displayName) · 按用量计费" : "本地模型 · \(engine.displayName) · 设备端运行"
        turnModel[id] = engine.modelId
        timeline.mark(.llm_started)
        let answer = try await engine.respond(conversationId: conversationId, turnId: id, voice: speakCurrentTurn && voice.isActive, onText: { [weak self] partial in
            self?.timeline.mark(.first_llm_token)
            self?.streamSpeech(TextSanitizer.plain(partial), id: id)
            self?.session.receiveAnswer(partial, for: id)
            self?.updateTurn(id: id, answer: partial)
        })
        #else
        // Watch: no on-device agent; answers come from the configured gateway.
        guard grants.contains(.cloudAI) else { throw AppFailure.message("Watch 需要在 iPhone 上配置云端后使用。") }
        guard !MandarinRouter.isPotentiallySensitive(text) || grants.contains(.cloudHealth) else { throw AppFailure.message("这可能包含健康信息，尚未获准发送到云端。") }
        sourceNote = "云端 AI · 按用量计费"
        let answer = try await gateway.respond(endpoint: archive.preferences.endpoint, token: token, turn: id, text: text, healthConsent: grants.contains(.cloudHealth),
                                               research: false, images: images, imageConsent: approvedImageTurn == id, onText: { [weak self] partial in
            self?.session.receiveAnswer(partial, for: id)
            self?.updateTurn(id: id, answer: partial)
        }, onSource: { _ in }, onDelivery: { [weak self] emotion in
            guard let self, self.session.generation == id else { return }
            self.voiceEmotion = emotion
        })
        #endif
        try Task.checkCancellation()
        guard session.generation == id else { return }
        complete(answer, question: text, id: id)
    }
    private func complete(_ answer: String, question: String, id: UUID) {
        let sessionOnly = (MandarinRouter.isPotentiallySensitive(question) || MandarinRouter.isPotentiallySensitive(answer)) && !grants.contains(.healthMemory)
        let model = turnModel.removeValue(forKey: id)
        Task { await conversationBackend?.recordAssistant(turnId: id, text: answer, final: true, failed: false, modelId: model, sessionOnly: sessionOnly) }
        session.receiveAnswer(answer, for: id)
        updateTurn(id: id, answer: answer, state: .complete)
        if grants.contains(.history), approvedImageTurn != id, !MandarinRouter.isPotentiallySensitive(question), !MandarinRouter.isPotentiallySensitive(answer) {
            archive.history.append(.init(id: id, question: question, answer: answer))
            archive.history.removeAll { $0.date < .now.addingTimeInterval(-30 * 86400) }
            archive.history = Array(archive.history.suffix(100)); persist()
        }
        for (stage, duration) in session.stages { logger.info("stage=\(stage, privacy: .public) elapsed=\(duration, privacy: .public)") }
        timeline.mark(.llm_completed)
        guard archive.preferences.speakResponses && speakCurrentTurn else {
            session.transition(.idle, for: id)
            if voice.isActive { flushTimeline(); applyVoice(.answerReady(willSpeak: false)) }
            return
        }
        if usesNeuralVoice, let neural = neuralSpeech {
            _ = voice.handle(.answerReady(willSpeak: true))
            if streamingTurn != id { startNeural(id: id) }
            #if os(iOS)
            let spokenAnswer = TextSanitizer.plain(answer)
            #else
            let spokenAnswer = answer
            #endif
            speak(splitter.finishChunks(spokenAnswer), on: neural); neural.finishInput()     // completion → playbackFinished → listen again
            return
        }
        #if os(iOS)
        // No other voice stands in on iPhone: without the voice engine (MOSS-TTS-Nano) the answer stays text only.
        session.transition(.idle, for: id)
        message = "还没有安装语音引擎，回答只显示文字。到 设置 › 声音 下载后即可朗读。"
        if voice.isActive { flushTimeline(); applyVoice(.answerReady(willSpeak: false)) }
        #else
        _ = voice.handle(.answerReady(willSpeak: true))
        do {
            session.transition(.speaking, for: id)
            // Explicit user style wins; health/consequential answers are spoken neutrally; otherwise the reply's intent.
            let consequential = MandarinRouter.isPotentiallySensitive(question) || MandarinRouter.isPotentiallySensitive(answer) || actionDraft != nil
            let style = SpeechStyle.resolve(userChoice: SpeechOutput.userStyle, intent: voiceEmotion, consequential: consequential,
                                            supported: SpeechOutput.supportedStyles)
            try speechOutput.speak(answer, style: style, emotion: voiceEmotion, onExpression: { [weak self] cue in
                guard let self, self.session.generation == id, self.session.phase == .speaking else { return }
                self.voiceEmotion = cue.emotion; self.speechEmphasis = cue.emphasis
            }, onWord: { [weak self] in
                guard let self, self.session.generation == id, self.session.phase == .speaking else { return }
                self.timeline.mark(.first_audio_played)
                self.speechBeat &+= 1
            }) { [weak self] in
                guard let self, self.session.generation == id else { return }
                self.lastPlaybackEnded = .now; self.speechEmphasis = 0.35
                self.voiceEmotion = .neutral; self.session.transition(.idle, for: id)
                self.timeline.mark(.playback_completed); self.flushTimeline()
                if self.voice.isActive { self.applyVoice(.playbackFinished) }   // continuous conversation: listen again
            }
        } catch { session.transition(.failed, for: id); message = error.localizedDescription }
        #endif
    }
    func confirmMemory() {
        guard let confirmation, confirmation.valid(), let content = memoryProposal,
              session.phase == .confirming, grants.contains(.memory) else { cancel(); message = "确认已过期，请重新发起。"; return }
        let sensitive = MandarinRouter.isPotentiallySensitive(content)
        guard !sensitive || grants.contains(.healthMemory) else { cancel(); return }
        let id = session.generation
        let record = MemoryRecord(content: content, sensitive: sensitive, sourceTurn: id)
        archive.memories.append(record)
        guard persist() else { archive.memories.removeAll { $0.id == record.id }; return }
        memoryProposal = nil; self.confirmation = nil
        session.transition(.thinking, for: id); complete("已保存这条记忆，你可以随时查看、编辑或删除。", question: session.transcript, id: id)
    }
    func saveAction(_ draft: ActionDraft) {
        guard !isSaving, session.phase == .confirming, actionDraft?.id == draft.id,
              grants.contains(draft.kind == .reminder ? .reminders : .calendar) else { return }
        isSaving = true; defer { isSaving = false }
        guard archive.actionOutcomes[draft.id.uuidString] == nil else { message = "这项操作已提交，请先在系统 App 中核对结果。"; return }
        archive.actionOutcomes[draft.id.uuidString] = "pending"
        guard persist() else { archive.actionOutcomes.removeValue(forKey: draft.id.uuidString); return }
        do {
            let externalID = try calendar.save(draft)
            archive.actionOutcomes[draft.id.uuidString] = externalID; persist()
            actionDraft = nil
            let id = session.generation; session.transition(.thinking, for: id)
            complete("已按你确认的标题和时间保存。", question: session.transcript, id: id)
        } catch { message = error.localizedDescription }
    }
    /// `keepRuns`: leave the agent run of the current conversation going (conversation switch, new chat). Its answer is
    /// written to its own conversation when it finishes. Explicit stop never passes this.
    func cancel(clear: Bool = false, keepRuns: Bool = false) {
        if !keepRuns, let index = conversation.firstIndex(where: { $0.id == session.generation && $0.state == .pending }) {
            conversation[index].state = .cancelled
            let turn = conversation[index]
            Task { await conversationBackend?.recordAssistant(turnId: turn.id, text: turn.answer, final: false, failed: false, modelId: nil, sessionOnly: false) }
        }
        operation?.cancel(); endpointTask?.cancel(); gateway.cancel(); speechOutput.stop()
        if !keepRuns { localChat?.cancel() }
        neuralSpeech?.stop(); streamingTurn = nil
        duplexRun = nil; bargeInEnabled = false; pendingTurnStart = nil
        #if os(iOS)
        cloudSpeech.stop()
        #endif
        session.cancel(); memoryProposal = nil; confirmation = nil; actionDraft = nil; researchSources = []
        audioLevel = 0; speechLevel = 0; speechEmphasis = 0.35; voiceEmotion = .neutral; readingMessage = false; approvedImageTurn = nil
        if clear { session = VoiceSession(); sourceNote = nil }
        Task { await speechInput.cancel() }
        companion?(.mic(.off))
        #if !os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: inferred
    // Why: Reading selected text through device speech must not create a conversation turn.
    // Debug Goal: Read local text, expose stop, and never re-arm the microphone after readout.
    // Search Tags: message read aloud no history voice userStop generation
    // Invariants:
    // - Readout does not record an assistant message or change stored conversation text.
    // - Cancel invalidates all readout callbacks before any new capture starts.
    // Failure Modes:
    // - Reusing complete() duplicates history; leaving voice active re-arms capture.
    func readAloud(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [.idle, .failed, .interrupted].contains(session.phase) else { return }
        _ = voice.handle(.userStop); cancel()
        #if os(iOS)
        guard let neural = neuralSpeech, neural.isReady else { message = "还没有安装语音引擎。到 设置 › 声音 下载后即可朗读。"; return }
        let rid = session.begin(); session.transition(.thinking, for: rid); readingMessage = true
        neural.onMetric = nil
        neural.begin(onLevel: { [weak self] level in
            guard let self, self.session.generation == rid else { return }; self.speechLevel = level; self.companion?(.speechLevel(level))
        }, onFirstAudio: { [weak self] in
            guard let self, self.session.generation == rid else { return }; self.session.transition(.speaking, for: rid)
        }, completed: { [weak self] _ in
            guard let self, self.session.generation == rid else { return }
            self.lastPlaybackEnded = .now; self.readingMessage = false; self.speechLevel = 0; self.session.transition(.idle, for: rid)
        })
        var reader = StreamingSpeechSplitter()
        neural.enqueue(reader.finish(text)); neural.finishInput()
        return
        #endif
        let id = session.begin(); session.transition(.thinking, for: id); readingMessage = true
        operation = Task { [weak self] in
            guard let self else { return }
            await self.speechInput.cancel()
            guard !Task.isCancelled, self.session.generation == id else { return }
            self.session.transition(.speaking, for: id)
            do {
                try self.speechOutput.speak(text, style: SpeechOutput.userStyle ?? .neutral, onExpression: { [weak self] cue in
                    guard let self, self.session.generation == id else { return }
                    self.voiceEmotion = cue.emotion; self.speechEmphasis = cue.emphasis
                }, onWord: { [weak self] in
                    guard let self, self.session.generation == id else { return }; self.speechBeat &+= 1
                }) { [weak self] in
                    guard let self, self.session.generation == id else { return }
                    self.lastPlaybackEnded = .now; self.readingMessage = false; self.voiceEmotion = .neutral
                    self.session.transition(.idle, for: id)
                }
            } catch {
                guard self.session.generation == id else { return }
                self.readingMessage = false; self.session.transition(.failed, for: id); self.message = error.localizedDescription
            }
        }
    }
    private func fail(_ error: Error, id: UUID) {
        guard session.generation == id, !(error is CancellationError) else { return }
        session.transition(.failed, for: id); message = error.localizedDescription
        if voice.isActive { _ = voice.handle(.processingFailed(error.localizedDescription)) }
        if let index = conversation.firstIndex(where: { $0.id == id }) { conversation[index].state = .failed; conversation[index].failure = error.localizedDescription }
        let partial = conversation.first { $0.id == id }?.answer ?? ""
        Task { await conversationBackend?.recordAssistant(turnId: id, text: partial, final: false, failed: true, modelId: nil, sessionOnly: false) }
        audioLevel = 0
        endpointTask?.cancel(); speechOutput.stop(); gateway.cancel(); neuralSpeech?.stop(); streamingTurn = nil
        duplexRun = nil; bargeInEnabled = false                     // the capture is torn down below; the next start rebuilds it
        #if os(iOS)
        cloudSpeech.stop()
        #endif
        speechLevel = 0
        Task { await speechInput.cancel() }
        companion?(.mic(.off))
    }
    private func updateTurn(id: UUID, answer: String, state: ConversationTurn.State? = nil) {
        guard session.generation == id, let index = conversation.firstIndex(where: { $0.id == id }) else { return }
        conversation[index].answer = answer
        if let state { conversation[index].state = state }
    }
    /// The on-device voice speaks whenever its engine is installed. There is no other voice engine to hand over to: without it the answer stays text.
    private var usesNeuralVoice: Bool {
        guard let neural = neuralSpeech else { return false }
        return neural.isReady
    }

    /// Streaming speech: each newly stable sentence of the answer is queued for synthesis while generation continues.
    private func streamSpeech(_ partial: String, id: UUID) {
        guard usesNeuralVoice, let neural = neuralSpeech, voice.isActive, speakCurrentTurn, archive.preferences.speakResponses,
              session.generation == id else { return }    // on-device synthesis: nothing leaves the phone
        if streamingTurn != id { startNeural(id: id) }
        if partial.isEmpty {
            // A new model step began (the text restarts at zero after a tool step): say what the previous step still held back, then count from the start again.
            speak(splitter.restart(flushing: stepText), on: neural); stepText = ""
            return
        }
        stepText = partial
        speak(splitter.updateChunks(partial), on: neural)
    }

    /// Queues chunks and remembers where each one's source starts, so the chunk that is playing can be located in the answer's segments.
    private func speak(_ chunks: [StreamingSpeechSplitter.Chunk], on neural: any StreamingSpeechEngine) {
        for chunk in chunks { companionChunks.append((chunk.text.count, chunk.sourceStart)) }
        speak(chunks.map(\.text), on: neural)
    }

    /// The speech clock: which queued chunk is playing, from what the engine reports as fully played (no audio-engine change needed).
    private func companionAdvanceChunk(turn: UUID) {
        guard companion != nil, let neural = neuralSpeech else { return }
        let played = neural.playedText.count
        var cumulative = 0, index = 0
        for chunk in companionChunks {
            guard cumulative + chunk.length <= played else { break }
            cumulative += chunk.length; index += 1
        }
        guard index != companionPlayedChunks, index < companionChunks.count else { return }
        companionPlayedChunks = index
        companion?(.speechChunk(turn: turn, sourceStart: companionChunks[index].start))
    }

    private func speak(_ chunks: [String], on neural: any StreamingSpeechEngine) {
        guard !chunks.isEmpty else { return }
        if !releasedFirstPhrase { releasedFirstPhrase = true; timeline.mark(.first_stable_phrase) }
        assistantSpeech += chunks.joined()
        neural.enqueue(chunks)
    }

    private func startNeural(id: UUID) {
        streamingTurn = id; splitter = StreamingSpeechSplitter(); stepText = ""
        companionChunks = []; companionPlayedChunks = -1
        companion?(.speechPreparing(turn: id))
        neuralSpeech?.onMetric = { [weak self] event in
            guard let self, self.session.generation == id else { return }
            self.timeline.mark(event)
        }
        neuralSpeech?.begin(onLevel: { [weak self] level in
            guard let self, self.session.generation == id else { return }
            self.speechLevel = level
            self.companion?(.speechLevel(level))
            self.companionAdvanceChunk(turn: id)
        }, onFirstAudio: { [weak self] in
            guard let self, self.session.generation == id else { return }
            self.timeline.mark(.first_audio_played); self.timeline.footprintMB = Self.footprintMB()
            self.session.transition(.speaking, for: id)
            self.companionAdvanceChunk(turn: id)
            _ = self.voice.handle(.answerReady(willSpeak: true))
        }, completed: { [weak self] _ in
            guard let self, self.session.generation == id else { return }
            self.streamingTurn = nil; self.lastPlaybackEnded = .now; self.timeline.mark(.playback_completed); self.speechLevel = 0
            self.session.transition(.idle, for: id)
            self.flushTimeline()
            if self.voice.isActive { self.applyVoice(.playbackFinished) }   // continuous conversation: listen again
        })
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }

    /// Appends this turn's timestamps (relative to end of speech, ms) to Documents/voice-metrics.jsonl. No text is written.
    private func flushTimeline() { writeTimeline(timeline); timeline = VoiceTimeline() }

    /// Monotonic seconds (`systemUptime`) for a wall-clock instant observed moments ago.
    private static func uptime(_ date: Date) -> Double { ProcessInfo.processInfo.systemUptime - Date.now.timeIntervalSince(date) }

    private func writeTimeline(_ timeline: VoiceTimeline) {
        if let line = timeline.jsonLine(), let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("voice-metrics.jsonl")
            if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((line + "\n").utf8)) }
            else { try? Data((line + "\n").utf8).write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication) }
            logger.info("voice_turn \(line, privacy: .public)")
        }
    }
    func newConversation() { _ = voice.handle(.userStop); cancel(clear: true, keepRuns: true); conversation = []; dictationDraft = nil; message = nil; conversationBackend?.beginNew(); companion?(.focus(conversation: nil)) }
    /// Opens a stored conversation (from the sidebar) and continues it.
    func openConversation(_ id: UUID) async {
        newConversation()
        guard let backend = conversationBackend else { return }
        conversation = await backend.open(id)
        companion?(.focus(conversation: id))
    }
    func openSavedTurn(_ entry: HistoryEntry) {
        guard grants.contains(.history), let saved = archive.history.first(where: { $0.id == entry.id }) else { return }
        newConversation()
        let id = session.begin()
        var turn = ConversationTurn(id: id, question: saved.question, createdAt: saved.date)
        turn.answer = saved.answer; turn.state = .complete; conversation = [turn]
        session.transition(.listening, for: id); session.receiveTranscript(saved.question, for: id)
        session.transition(.finalizing, for: id); session.transition(.thinking, for: id)
        session.receiveAnswer(saved.answer, for: id); session.transition(.idle, for: id)
        sourceNote = "本机保存的消息"
    }
    private func appendTurn(_ turn: ConversationTurn) {
        conversation.append(turn)
        while conversation.count > 80 || conversation.reduce(0, { $0 + $1.images.reduce(0, { $0 + $1.data.count }) }) > 12_000_000 {
            conversation.removeFirst()
        }
    }
    func refreshAccount() async {
        // CONTEXT MEMORY
        // Updated: 2026-10-27
        // Status: inferred
        // Why: Account refresh can outlive a change to the service or credentials.
        // Debug Goal: Never show the previous service's models, rates, or balance as current.
        // Search Tags: account refresh stale service credentials model rates
        // Invariants:
        // - Apply a response only to the service and token that requested it.
        // - A failed refresh clears the last unverified account snapshot.
        // Failure Modes:
        // - A slow previous request overwrites a newer service configuration.
        // - A failed request leaves stale prices or model identity visible.
        accountRefreshGeneration &+= 1
        let generation = accountRefreshGeneration
        let endpoint = archive.preferences.endpoint, credential = token
        do {
            let result = try await gateway.account(endpoint: endpoint, token: credential)
            guard generation == accountRefreshGeneration, endpoint == archive.preferences.endpoint, credential == token else { return }
            account = result
        } catch {
            guard generation == accountRefreshGeneration, endpoint == archive.preferences.endpoint, credential == token else { return }
            account = nil; message = error.localizedDescription
        }
    }
    func editMemory(id: UUID, text: String, revision: Int) {
        guard let index = archive.memories.firstIndex(where: { $0.id == id }) else { return }
        if MandarinRouter.isPotentiallySensitive(text) && !grants.contains(.healthMemory) { message = "健康信息需要单独授权。"; return }
        do { try archive.memories[index].edit(text, expectedRevision: revision); archive.memories[index].sensitive = MandarinRouter.isPotentiallySensitive(text); persist() }
        catch { message = "记忆已被更新，请重新打开后编辑。" }
    }
    func deleteMemory(_ id: UUID) { archive.memories.removeAll { $0.id == id }; reviewing = []; persist() }
    func reviewMemory() {
        guard grants.contains(.consolidation), grants.contains(.history), grants.contains(.memory) else { message = "请先开启历史、长期记忆和本地记忆整理。"; return }
        reviewing = MemoryReview.candidates(from: archive.history, existing: archive.memories)
    }
    func saveReviewedCandidate(_ proposal: ConsolidationProposal) {
        guard grants.contains(.memory), grants.contains(.consolidation), reviewing.contains(where: { $0.id == proposal.id }),
              let source = proposal.sources.first, archive.history.contains(where: { $0.id == source }),
              !MandarinRouter.isPotentiallySensitive(proposal.content) else { message = "来源或授权已变化，请重新整理。"; return }
        let record = MemoryRecord(content: proposal.content, sensitive: false, sourceTurn: source)
        archive.memories.append(record)
        guard persist() else { archive.memories.removeAll { $0.id == record.id }; return }
        reviewing.removeAll { $0.id == proposal.id }
    }
    func exportData() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "iTalk-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "italk-export.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    func deleteAll() {
        accountRefreshGeneration &+= 1
        newConversation()
        do {
            try disk?.remove()
            let export = URL.temporaryDirectory.appending(path: "iTalk-export", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: export.path) { try FileManager.default.removeItem(at: export) }
            archive = PrivateArchive(); account = nil; reviewing = []; message = "已删除本机数据和凭证；系统健康、日历及服务器账本未被修改。"
        }
        catch { message = "删除失败，请解锁后重试。" }
    }
}
