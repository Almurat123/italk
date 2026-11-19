import AVFoundation
import Speech
import Foundation
import OSLog
import AssistantCore

// CONTEXT MEMORY
// Updated: 2026-10-29
// Status: inferred
// Why: Capture used to start the microphone last, after the permission prompt, language-asset check, analyzer preparation and
//      audio-session activation. Everything said while those ran was lost, so held dictation and the first words of a spoken turn
//      were missing.
// Debug Goal: The microphone runs first and keeps every sample in a pre-roll buffer; recognition attaches afterwards and receives
//      the buffered audio before live audio, so no word spoken after the request can be lost.
// Search Tags: pre-roll ring buffer capture start lost first words hold dictation recognizer attach
// Invariants:
// - MicCapture owns the engine and the audio session; it starts before any recognizer work and never waits for it.
// - The ring buffer holds up to 90 s of 16 kHz mono float audio; attach() drains it and goes live under one lock, so nothing is
//   dropped or duplicated between the backlog and live audio.
// - The analyzer input stream is unbounded: the pre-roll burst must never be dropped.
// - Hardware calls (category, activation, engine start/stop) run on one serial queue, never on the main thread.
// - Session deactivation is deferred and skipped when another component has taken the session (playback) or capture restarted.
// Failure Modes:
// - Awaiting asset download or analyzer preparation before engine.start() loses the beginning again.
// - A bounded stream policy drops the oldest buffered audio exactly when the backlog is largest.
// - Deactivating the session after playback has started silences the answer.

/// Everything that touches audio hardware runs here, in order, off the main thread.
private enum AudioHardware {
    static let queue = DispatchQueue(label: "com.italk.assistant.capture-session", qos: .userInteractive)
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Microphone → 16 kHz mono float buffers, kept in a pre-roll ring until a consumer attaches.
final class MicCapture: @unchecked Sendable {
    struct Started: Sendable { var echoCancelled: Bool; var inputRate: Double; var route: String? }
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let engine = AVAudioEngine()
    /// Up to 90 s of 16 kHz audio waiting for a recognizer (see PreRollBuffer for the no-loss guarantee).
    private let preRoll = PreRollBuffer<AVAudioPCMBuffer>(maxFrames: 16_000 * 90) { Int($0.frameLength) }
    private var converter: AVAudioConverter?
    private var vad = EnergyVAD()
    private var reportedFirst = false
    private var tapped = false
    private var stopped = false
    private let activity: @Sendable (Double, Bool) -> Void
    private let firstBuffer: @Sendable (Int) -> Void

    init(activity: @escaping @Sendable (Double, Bool) -> Void, firstBuffer: @escaping @Sendable (Int) -> Void) {
        self.activity = activity; self.firstBuffer = firstBuffer
    }

    /// Configures the session, installs the tap and starts the engine. Returns as soon as audio is flowing.
    func start(duplex: Bool, preferEchoCancellation: Bool = true) async throws -> Started {
        try await AudioHardware.perform { [self] in
            let audio = AVAudioSession.sharedInstance()
            if duplex {
                // Mode must be .default for system echo cancellation. A2DP keeps AirPods output in high quality (the built-in
                // mic records); defaultToSpeaker avoids the quiet receiver.
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                if #available(iOS 18.2, *), audio.isEchoCancelledInputAvailable { try? audio.setPrefersEchoCancelledInput(preferEchoCancellation) }
            } else if audio.category != .record || audio.mode != .measurement {
                try audio.setCategory(.record, mode: .measurement, options: [])
            }
            try audio.setActive(true)
            let source = engine.inputNode.outputFormat(forBus: 0)
            guard source.sampleRate > 0, source.channelCount > 0, let converter = AVAudioConverter(from: source, to: Self.format) else {
                throw AppFailure.message("当前音频输入不可用，请检查耳机和麦克风。")
            }
            self.converter = converter
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { [self] buffer, _ in ingest(buffer) }
            tapped = true
            engine.prepare()
            try engine.start()
            var aec = false
            if #available(iOS 18.2, *) { aec = duplex && audio.isEchoCancelledInputEnabled }
            return Started(echoCancelled: aec, inputRate: source.sampleRate, route: audio.currentRoute.inputs.first?.portType.rawValue)
        }
    }

    /// Runs on the audio thread.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        if !reportedFirst { reportedFirst = true; firstBuffer(Int(buffer.frameLength)) }
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let db = 20 * log10(max(Double(sqrt(sum / Float(buffer.frameLength))), 0.00001))
            let voiced = vad.process(levelDB: db)
            activity(min(1, max(0, (db + 55) / 45)), voiced)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var supplied = false, error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        preRoll.push(out)
    }

    /// Hands every buffered buffer to `consumer` in order, then every later one as it arrives (atomically: nothing is lost
    /// between the backlog and live audio).
    func attach(_ consumer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { preRoll.attach(consumer) }

    /// Seconds of audio waiting for a consumer.
    var backlogSeconds: Double { Double(preRoll.pendingFrames) / 16_000 }

    func stop() {
        AudioHardware.queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            engine.stop()
            if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        }
    }

    /// Debug: the exact tap block the engine uses, for the isolation check.
    func makeTapBlock() -> AVAudioNodeTapBlock { { @Sendable [self] buffer, _ in ingest(buffer) } }
    func prepareForTesting(source: AVAudioFormat) { converter = AVAudioConverter(from: source, to: Self.format) }
}

/// A prepared speech recognizer: transcriber + detector + analyzer loaded for one capture. Single use.
@MainActor private final class RecognizerKit {
    let modules: [any SpeechModule]
    let detector: SpeechDetector
    let analyzer: SpeechAnalyzer
    let target: AVAudioFormat
    let readResults: (@escaping @MainActor (String) -> Void, @escaping @MainActor (Error) -> Void) -> Task<Void, Never>
    let createdAt = Date.now

    init(modules: [any SpeechModule], detector: SpeechDetector, analyzer: SpeechAnalyzer, target: AVAudioFormat,
         readResults: @escaping (@escaping @MainActor (String) -> Void, @escaping @MainActor (Error) -> Void) -> Task<Void, Never>) {
        self.modules = modules; self.detector = detector; self.analyzer = analyzer; self.target = target; self.readResults = readResults
    }

    /// Creates the transcriber for Mandarin, installs language assets if needed (reporting it), and loads the analyzer.
    static func prepare(onDownloading: @MainActor (Bool) -> Void) async throws -> RecognizerKit {
        let locale = Locale(identifier: "zh-CN")
        let module: any SpeechModule
        let reader: (@escaping @MainActor (String) -> Void, @escaping @MainActor (Error) -> Void) -> Task<Void, Never>
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            module = transcriber
            reader = { callback, onError in Task { @MainActor in
                var committed = ""
                do { for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { committed += text; callback(committed) } else { callback(committed + text) }
                } } catch { if !Task.isCancelled { onError(error) } }
            } }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
            module = transcriber
            reader = { callback, onError in Task { @MainActor in
                var committed = ""
                do { for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { committed += text; callback(committed) } else { callback(committed + text) }
                } } catch { if !Task.isCancelled { onError(error) } }
            } }
        } else { throw AppFailure.message("此设备的本地普通话识别暂不可用，可使用文字输入。") }
        // iOS 26 on-device voice activity detector (no download). Runs in the same analyzer as the transcriber.
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [module, detector]
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            onDownloading(true)
            try await installation.downloadAndInstall()
            onDownloading(false)
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppFailure.message("当前音频输入不可用，请检查耳机和麦克风。")
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: target)
        return RecognizerKit(modules: modules, detector: detector, analyzer: analyzer, target: target, readResults: reader)
    }
}

/// Converts the capture format (16 kHz mono float) to what the analyzer wants; a no-op when they already match.
private final class AnalyzerFeed: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target; self.continuation = continuation
        converter = target == MicCapture.format ? nil : AVAudioConverter(from: MicCapture.format, to: target)
    }
    func yield(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / MicCapture.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false, error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
}

@MainActor final class SpeechInput {
    private var capture: MicCapture?
    private var kit: RecognizerKit?
    private var warmKit: RecognizerKit?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var deactivation: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var sessionHeld = false
    private var run = UUID()
    private let log = Logger(subsystem: "com.italk.assistant", category: "audio")
    /// The running capture is echo-cancelled (assistant speech removed from the microphone signal), so it may keep
    /// listening while the assistant talks on the speaker.
    private(set) var echoCancelled = false
    private(set) var duplex = false
    /// The recognizer is consuming audio (the backlog has been handed over).
    private(set) var recognizerReady = false

    // CONTEXT MEMORY
    // Updated: 2026-10-29
    // Status: inferred
    // Why: Loading speech assets and the analyzer after the finger is down delays text; doing it earlier removes the wait.
    // Debug Goal: Keep one prepared recognizer ready while dictation is likely, without recording any audio.
    // Search Tags: hold dictation early speech warmup recognition assets prepared analyzer
    // Invariants:
    // - Warmup never activates the microphone or changes recording consent.
    // - A prepared recognizer is single use and expires after 90 s; actual capture never depends on it.
    // Failure Modes:
    // - Warming immediately on app launch can create unwanted background work.
    func warmDictationAssets() {
        guard warmTask == nil, warmKit == nil || Date.now.timeIntervalSince(warmKit!.createdAt) > 90 else { return }
        warmTask = Task { [weak self] in
            defer { self?.warmTask = nil }
            guard let kit = try? await RecognizerKit.prepare(onDownloading: { _ in }) else { return }
            self?.warmKit = kit
            // An unused prepared recognizer holds speech models in memory: let it go after it has expired.
            try? await Task.sleep(for: .seconds(95))
            if let self, self.warmKit === kit { self.warmKit = nil; await kit.analyzer.cancelAndFinishNow() }
        }
    }

    /// `duplex`: one continuous capture for a whole voice session that keeps running while the assistant speaks
    /// (`.playAndRecord` + system echo cancellation). Otherwise a one-shot `.record` capture (dictation).
    ///
    /// Returns as soon as the microphone is delivering audio. Recognition attaches afterwards (it receives everything captured
    /// since the call), so slow language assets or analyzer loading delay text, never words. Failures after that point arrive
    /// through `onError`.
    func start(duplex: Bool = false, preferEchoCancellation: Bool = true, onText: @escaping @MainActor (String) -> Void, onActivity: @escaping @MainActor () -> Void,
               onError: @escaping @MainActor (Error) -> Void, onLevel: @escaping @MainActor (Double) -> Void = { _ in },
               onStage: @escaping @MainActor (CaptureStage) -> Void = { _ in }) async throws {
        teardownRecognizer()
        capture?.stop(); capture = nil
        let id = UUID(); run = id
        deactivation?.cancel(); deactivation = nil
        onStage(.requested)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .denied: throw AppFailure.message("请在系统设置中允许麦克风访问。")
        default: guard await AVAudioApplication.requestRecordPermission() else { throw AppFailure.message("请在系统设置中允许麦克风访问。") }
        }
        guard run == id else { throw CancellationError() }

        // 1. The microphone first. From here on every sample is kept.
        let capture = MicCapture(activity: { level, voiced in
            Task { @MainActor in onLevel(level); if voiced { onActivity() } }
        }, firstBuffer: { frames in Task { @MainActor in onStage(.firstBuffer(frames: frames)) } })
        self.capture = capture
        sessionHeld = true
        let started: MicCapture.Started
        do { started = try await capture.start(duplex: duplex, preferEchoCancellation: preferEchoCancellation) }
        catch { if run == id { capture.stop(); self.capture = nil; sessionHeld = false; scheduleDeactivation() }; throw error }
        guard run == id else { capture.stop(); throw CancellationError() }
        self.duplex = duplex; echoCancelled = started.echoCancelled
        log.info("capture duplex=\(duplex, privacy: .public) aec=\(started.echoCancelled, privacy: .public) rate=\(started.inputRate, privacy: .public) route=\(started.route ?? "-", privacy: .public)")
        onStage(.micRunning)

        // 2. The recognizer prepares while audio is already being kept, then receives the backlog and live audio.
        recognizerReady = false
        recognizerTask = Task { @MainActor [weak self] in
            await self?.attachRecognizer(id: id, capture: capture, onText: onText, onActivity: onActivity, onError: onError, onStage: onStage)
        }
    }

    private func attachRecognizer(id: UUID, capture: MicCapture, onText: @escaping @MainActor (String) -> Void,
                                  onActivity: @escaping @MainActor () -> Void, onError: @escaping @MainActor (Error) -> Void,
                                  onStage: @escaping @MainActor (CaptureStage) -> Void) async {
        do {
            let kit: RecognizerKit
            if let warm = warmKit, Date.now.timeIntervalSince(warm.createdAt) < 90 { kit = warm; warmKit = nil }
            else {
                onStage(.recognizerPreparing(downloading: false))
                kit = try await RecognizerKit.prepare(onDownloading: { onStage(.recognizerPreparing(downloading: $0)) })
            }
            try Task.checkCancellation()
            guard run == id else { return }
            self.kit = kit
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            var sawText = false
            resultsTask = kit.readResults({ text in
                if !sawText && !text.isEmpty { sawText = true; onStage(.firstText) }
                onText(text)
            }, onError)
            let detector = kit.detector
            detectorTask = Task { @MainActor in
                do { for try await r in detector.results where r.speechDetected { onActivity() } } catch {}
            }
            let analyzer = kit.analyzer
            analysisTask = Task { do { try await analyzer.start(inputSequence: stream) } catch { if !Task.isCancelled { await onError(error) } } }
            let feed = AnalyzerFeed(target: kit.target, continuation: continuation)
            let backlog = capture.backlogSeconds
            capture.attach { feed.yield($0) }
            recognizerReady = true
            log.info("recognizer attached backlog=\(backlog, privacy: .public)s")
            onStage(.recognizerReady)
        } catch {
            if run == id, !(error is CancellationError) { onError(error) }
        }
    }

    private func teardownRecognizer() {
        recognizerTask?.cancel(); recognizerTask = nil
        resultsTask?.cancel(); resultsTask = nil
        analysisTask?.cancel(); analysisTask = nil
        detectorTask?.cancel(); detectorTask = nil
        continuation?.finish(); continuation = nil
        recognizerReady = false
    }

    /// Stops listening and returns the final text through the callbacks already installed. Everything captured is recognized
    /// before this returns (the caller bounds the wait).
    func finish() async throws {
        let id = run
        capture?.stop()
        await recognizerTask?.value                    // waits until the backlog has been handed to the analyzer
        guard run == id else { throw CancellationError() }
        let pendingResults = resultsTask
        continuation?.finish(); continuation = nil
        try await kit?.analyzer.finalizeAndFinishThroughEndOfInput()
        await pendingResults?.value
        guard run == id else { throw CancellationError() }
        kit = nil; capture = nil; teardownRecognizer(); echoCancelled = false; duplex = false
        sessionHeld = false
        scheduleDeactivation()
    }

    func cancel() async {
        run = UUID()
        capture?.stop(); capture = nil
        let previous = kit?.analyzer; kit = nil
        teardownRecognizer()
        echoCancelled = false; duplex = false
        sessionHeld = false
        scheduleDeactivation()
        await previous?.cancelAndFinishNow()
    }

    /// Releases the audio session shortly after capture ends, unless capture restarts first (consecutive captures keep the
    /// session) or another component has taken it over (playback must never be cut off by this).
    private func scheduleDeactivation() {
        deactivation?.cancel()
        deactivation = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.sessionHeld else { return }
            _ = try? await AudioHardware.perform {
                let audio = AVAudioSession.sharedInstance()
                guard audio.category == .record else { return }          // playback or a voice session owns it now
                try audio.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
    }

    #if DEBUG
    private final class TapProbe: @unchecked Sendable {
        let block: AVAudioNodeTapBlock
        init(_ block: @escaping AVAudioNodeTapBlock) { self.block = block }
    }
    static func verifyTapIsolation() async throws -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return false }
        let capture = MicCapture(activity: { _, _ in }, firstBuffer: { _ in })
        capture.prepareForTesting(source: format)
        let probe = TapProbe(capture.makeTapBlock())
        return await withCheckedContinuation { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                    completion.resume(returning: false); return
                }
                buffer.frameLength = 1024
                if let samples = buffer.floatChannelData?[0] { samples.initialize(repeating: 0, count: 1024) }
                probe.block(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
                completion.resume(returning: capture.backlogSeconds > 0)
            }
        }
    }
    #endif
}
