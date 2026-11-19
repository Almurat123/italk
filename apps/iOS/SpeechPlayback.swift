import Foundation
import AVFoundation
import os
import AssistantCore
import NeuralSpeech

// CONTEXT MEMORY
// Updated: 2026-10-29
// Status: inferred
// Why: The first neural pipeline waited for a whole synthesized sentence before scheduling it, joined sentences with whatever
//      silence each one happened to carry, started the audio engine cold for every answer, and could not stream.
// Debug Goal: First audio as soon as the engine has speech, sentences joined with designed pauses, no clipped first syllable,
//      no clicks, and playback that survives a slow engine without garbling.
// Search Tags: neural speech playback streaming prebuffer pause trim silence bluetooth lead-in underrun first audio
// Invariants:
// - The engine (MOSS-TTS-Nano, the only one) delivers mono float PCM as a stream, one 80 ms frame at a time. There is no second engine to fall back to.
// - Leading silence of every sentence is trimmed, trailing silence trimmed after a short hold-back, and the pause between
//   sentences comes from the closing punctuation (AudioTrim.pause), so rhythm does not depend on the engine.
// - Playback starts when ~0.3 s of speech is scheduled (or the sentence ended); an underrun is logged, never hidden.
// - Every scheduled buffer belongs to one generation; stop() invalidates all callbacks before anything new starts.
// - The text reported by `playedText` is only what finished playing.
// Failure Modes:
// - Scheduling synthesized audio from a stopped generation plays a stale sentence after a barge-in.
// - Starting the player before anything is scheduled makes the first word depend on route wake-up (Bluetooth clips it).
// - Reconnecting the player graph while the engine runs crashes.

/// One playback queue for neural speech: text arrives in stable chunks while the answer is still being generated, synthesis
/// streams audio into the queue, and `completed` fires once after `finishInput()` when everything has finished playing.
@MainActor final class NeuralSpeechOutput: StreamingSpeechEngine {
    private let center: NeuralVoiceCenter
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let stretch = AVAudioUnitTimePitch()
    private var connectedRate = 0.0
    private var generation = 0
    private var input: AsyncStream<String>.Continuation?
    private var worker: Task<Void, Never>?
    private var scheduled = 0, played = 0, inputDone = false
    private var scheduledSeconds = 0.0
    private var playing = false
    private var underruns = 0
    /// Underruns of the most recent answer (diagnostics).
    private(set) var lastUnderruns = 0
    private var leadInPending = false
    private(set) var playedText = ""
    /// Speak with this voice instead of the selected one (the voice page's preview).
    var voiceOverride: String?
    private var streaming = false
    private var beganAt: ContinuousClock.Instant?
    var onMetric: (@MainActor (VoiceTimeline.Event) -> Void)?
    private var onLevel: (@MainActor (Double) -> Void)?
    private var onFirstAudio: (@MainActor () -> Void)?
    private var completed: (@MainActor (Bool) -> Void)?
    private let log = Logger(subsystem: "com.italk.assistant", category: "neural-tts")

    init(center: NeuralVoiceCenter) {
        self.center = center
        engine.attach(player)
        engine.attach(stretch)
    }

    var isReady: Bool { center.canSpeak }
    func warmUp() { if isReady { center.warmUp() } }

    // MARK: Session

    func begin(onLevel: @escaping @MainActor (Double) -> Void, onFirstAudio: @escaping @MainActor () -> Void, completed: @escaping @MainActor (Bool) -> Void) {
        stop()
        generation += 1
        let gen = generation
        self.onLevel = onLevel; self.completed = completed; self.onFirstAudio = onFirstAudio
        scheduled = 0; played = 0; inputDone = false; playedText = ""; playing = false; scheduledSeconds = 0; underruns = 0
        streaming = true; center.streamStarted(); beganAt = .now
        // The engine is not installed: nothing is spoken (the caller keeps the text and says why). No other voice takes over.
        guard let route = center.route(voice: voiceOverride) else { fail(gen); return }
        let rate = route.synth.sampleRate
        do {
            let session = AVAudioSession.sharedInstance()
            // During a voice session the echo-cancelled capture owns a .playAndRecord session: never switch categories
            // under it (that would stop the microphone and cost a route change per answer).
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            }
            try connect(rate: rate, speed: route.synth.supportsNativeSpeed ? 1 : route.speed)
            installLevelTap(gen: gen)
            // The engine runs while the first sentence is synthesized, so the output route is awake when audio is ready.
            try engine.start()
        } catch { log.error("audio start failed: \(error.localizedDescription, privacy: .public)"); fail(gen); return }
        leadInPending = Self.routeNeedsLeadIn
        let (stream, continuation) = AsyncStream<String>.makeStream()
        input = continuation
        worker = Task { [weak self] in await self?.run(stream, route: route, gen: gen) }
    }

    private func fail(_ gen: Int) {
        let done = completed; completed = nil
        guard generation == gen else { return }
        finishStream()
        done?(false)
    }

    private func finishStream() {
        guard streaming else { return }
        streaming = false
        center.streamEnded()
    }

    func enqueue(_ chunks: [String]) { for c in chunks where !c.isEmpty { input?.yield(c) } }
    func finishInput() { input?.finish(); input = nil }

    func stop() {
        generation += 1
        input?.finish(); input = nil
        worker?.cancel(); worker = nil
        player.stop()
        if engine.isRunning { engine.mainMixerNode.removeTap(onBus: 0); engine.stop() }
        onLevel?(0); onLevel = nil
        completed = nil; onFirstAudio = nil
        playing = false
        finishStream()
    }

    private func connect(rate: Double, speed: Float) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw AppFailure.message("无法建立语音播放。") }
        if connectedRate != rate {
            engine.connect(player, to: stretch, format: format)
            engine.connect(stretch, to: engine.mainMixerNode, format: format)
            connectedRate = rate
        }
        stretch.rate = max(0.5, min(2, speed))
    }

    /// Bluetooth routes wake up slowly and clip the first syllable; a short run of silence in front absorbs it.
    private static var routeNeedsLeadIn: Bool {
        let wireless: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { wireless.contains($0.portType) }
    }

    // MARK: Synthesis → queue

    private func run(_ stream: AsyncStream<String>, route: NeuralRoute, gen: Int) async {
        var first = true
        for await text in stream {
            guard generation == gen, !Task.isCancelled else { return }
            do { try await speak(text, route: route, gen: gen, first: first) }
            catch is CancellationError { return }
            catch { log.error("synthesis failed: \(error.localizedDescription, privacy: .public)") }
            first = false
        }
        guard generation == gen else { return }
        inputDone = true
        startPlayback(gen: gen, force: true)
        checkDone(gen: gen)
    }

    /// Streams one chunk of text through the engine into the player queue.
    private func speak(_ text: String, route: NeuralRoute, gen: Int, first: Bool) async throws {
        if first { onMetric?(.tts_synthesis_started) }
        let rate = route.synth.sampleRate
        let hold = Int(rate * 0.16)                       // tail kept back until we know whether it is silence
        var pending: [Float] = []
        var started = false, produced = 0
        let begun = ContinuousClock.now
        let style: String? = nil          // neutral; a delivery style is only ever chosen from declared metadata, never from keywords in the text
        for try await pcm in route.synth.stream(text, voice: route.voice, speed: route.speed, style: style) {
            guard generation == gen else { throw CancellationError() }
            produced += pcm.count
            pending += pcm
            if !started {
                guard let silent = AudioTrim.leadingSilence(pending, rate: rate) else { continue }   // still silence: wait for speech
                pending.removeFirst(max(0, silent - Int(rate * 0.02)))
                started = true
            }
            let ready = pending.count - hold
            if ready >= Int(rate * 0.12) {
                schedule(Array(pending.prefix(ready)), rate: rate, gen: gen, spokenText: nil)
                pending.removeFirst(ready)
            }
        }
        guard generation == gen, started else { return }
        let trailing = AudioTrim.trailingSilence(pending, rate: rate)
        if trailing > 0 { pending.removeLast(min(pending.count, trailing)) }
        AudioTrim.fade(&pending, rate: rate, inMs: 0, outMs: 8)
        // The chunk's text counts as heard when its last speech buffer has played.
        if !pending.isEmpty { schedule(pending, rate: rate, gen: gen, spokenText: text) }
        else { markHeardOnLastBuffer(text, gen: gen) }
        schedule([Float](repeating: 0, count: Int(rate * AudioTrim.pause(after: text))), rate: rate, gen: gen, spokenText: nil)
        let elapsed = ContinuousClock.now - begun
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        center.noteSynthesis(seconds: seconds, audioSeconds: Double(produced) / rate)
    }

    private func markHeardOnLastBuffer(_ text: String, gen: Int) {
        // Everything of this chunk was already scheduled in earlier slices: attach the text to a zero-length marker.
        guard let format = connectedFormat, let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        marker.frameLength = 1
        marker.floatChannelData?[0][0] = 0
        scheduled += 1
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack,
                              completionHandler: Self.playedCallback { [weak self] in Task { @MainActor in self?.bufferPlayed(gen: gen, text: text) } })
    }

    private var connectedFormat: AVAudioFormat? { connectedRate > 0 ? AVAudioFormat(standardFormatWithSampleRate: connectedRate, channels: 1) : nil }

    private func schedule(_ samples: [Float], rate: Double, gen: Int, spokenText: String?) {
        guard generation == gen, !samples.isEmpty, let format = connectedFormat else { return }
        var body = samples
        if leadInPending {
            leadInPending = false
            body = [Float](repeating: 0, count: Int(rate * 0.25)) + body
        }
        guard body.count <= Int(UInt32.max), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(body.count)),
              let destination = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(body.count)
        body.withUnsafeBufferPointer { src in if let base = src.baseAddress { destination.update(from: base, count: src.count) } }
        if scheduled == 0 { onMetric?(.first_pcm_ready) }
        scheduled += 1
        scheduledSeconds += Double(body.count) / rate
        let text = spokenText
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                              completionHandler: Self.playedCallback { [weak self] in Task { @MainActor in self?.bufferPlayed(gen: gen, text: text) } })
        startPlayback(gen: gen, force: false)
    }

    /// Starts the player once enough speech is queued to stay ahead of it (or the answer is complete).
    private func startPlayback(gen: Int, force: Bool) {
        guard generation == gen, !playing, scheduled > 0 else { return }
        let lead = center.leadSeconds()
        guard force || scheduledSeconds >= lead else { return }
        playing = true
        player.play()
        if let beganAt { center.noteFirstAudio(ms: Self.milliseconds(ContinuousClock.now - beganAt)); self.beganAt = nil }
        onFirstAudio?()
    }

    private func bufferPlayed(gen: Int, text: String?) {
        guard gen == generation else { return }
        played += 1
        if let text { playedText += text }
        // The queue ran dry while more speech was still being produced: an audible gap. Recorded so the lead can grow.
        if playing, !inputDone, played >= scheduled { underruns += 1; center.noteUnderrun(); log.notice("playback underrun #\(self.underruns, privacy: .public)") }
        checkDone(gen: gen)
    }

    private func checkDone(gen: Int) {
        guard gen == generation, inputDone, played >= scheduled else { return }
        let done = completed; completed = nil
        lastUnderruns = underruns
        if underruns == 0 { center.noteCleanAnswer() }
        player.stop()
        if engine.isRunning { engine.mainMixerNode.removeTap(onBus: 0); engine.stop() }
        onLevel?(0)
        // Keep the voice session's capture alive; only a playback-only session is released.
        if AVAudioSession.sharedInstance().category != .playAndRecord {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        finishStream()
        done?(true)
    }

    // MARK: Level metering

    /// Real output level (what is actually being played), for the character's mouth/orb.
    private func installLevelTap(gen: Int) {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                        block: Self.levelTap { [weak self] level in Task { @MainActor in guard let self, self.generation == gen else { return }; self.onLevel?(level) } })
    }

    // Audio-thread callbacks are built outside MainActor isolation: a closure created in this @MainActor class would
    // inherit the isolation and trap on the render thread (same crash class as the microphone tap).
    nonisolated private static func levelTap(_ report: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let db = 20 * log10(max(Double(sqrt(sum / Float(buffer.frameLength))), 0.00001))
            report(min(1, max(0, (db + 50) / 44)))
        }
    }
    nonisolated private static func milliseconds(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }
    nonisolated private static func playedCallback(_ done: @escaping @Sendable () -> Void) -> AVAudioPlayerNodeCompletionHandler {
        { _ in done() }
    }
}
