import Foundation
import AVFoundation
import Observation
import os
import AgentRuntime
import NeuralSpeech
import AssistantCore

// CONTEXT MEMORY
// Updated: 2026-10-30
// Status: inferred (unit-tested policy; device behaviour is checked with the TTS probe and on the phone)
// Why: The phone showed the natural voices as "ready" while every answer was still spoken by the retired Kokoro voice: one calibration taken
//      with the phone locked (1.46x real time) was stored for good and `usesMoss` returned false. Tapping a voice only wrote a preference.
// Debug Goal: One engine (MOSS-TTS-Nano, Chinese and English in one voice). Selecting a voice selects it and plays it. Nothing is ever spoken
//      by another engine; if the engine is missing the answer stays text and the app says why.
// Search Tags: voice engine moss download preview select delete storage legacy kokoro cleanup speed lead
// Invariants:
// - `route()` returns the MOSS route or nil. There is no second engine and no speed-based switch.
// - Speed numbers (median of real syntheses) only size the playback lead and are shown to the person.
// - Retired Kokoro files and voice ids are removed/mapped once, with the freed size reported.
// - A voice row selects the voice (checkmark) and previews it through the same output class the answers use.
// Failure Modes:
// - Persisting a calibration made in the background poisons later launches.
// - Deleting the weights while an answer is playing leaves the output without a model; deletion is refused while speech is active.

/// One voice of the engine. All voices share one set of weights; a voice is a few kilobytes of reference codes.
struct VoiceOption: Identifiable, Equatable {
    enum Gender: String { case female, male }
    let id: String            // e.g. "moss-yunshu"
    let name: String
    let note: String
    let gender: Gender
}

/// Which engine speaks, which voice, and what the player needs to know about it.
struct NeuralRoute {
    let synth: any NeuralSynthesizer
    let voice: String
    let speed: Float
}

struct LegacyCleanupReport: Equatable {
    var bytes: Int64
    var items: Int
}

/// Installs and owns the on-device bilingual voice engine. Same verified, multi-source distribution as the language models.
@MainActor @Observable final class NeuralVoiceCenter {
    enum State: Equatable { case unavailable, notInstalled, downloading(DownloadProgress), verifying, installed, failed(String) }
    enum Preview: Equatable { case idle, preparing(String), playing(String), failed(String) }

    static let voiceKey = "italk.voice.neural.id", speedKey = "italk.voice.neural.speed"
    private static let speedMedianKey = "italk.voice.speed.median.v2"
    private static let cleanupKey = "italk.voice.legacy-cleanup.v1"
    /// Keys of earlier versions. The speed key held a locked-phone calibration (1.46x) that disabled the engine; it is deleted, not reused.
    private static let obsoleteKeys = ["italk.voice.moss.rtf", "italk.voice.engine", "italk.voice.migrated.v2"]

    /// The built-in voices (reference-code sets; they share one set of weights).
    static let voices: [VoiceOption] = MossVoiceLibrary.voices.map { v in
        let info = MossVoiceLibrary.info[v.id]
        return VoiceOption(id: v.id, name: info?.name ?? v.name, note: info?.note ?? "", gender: (info?.female ?? true) ? .female : .male)
    }
    static func displayName(for id: String) -> String { voices.first { $0.id == id }?.name ?? "未选择" }
    private static var defaultVoice: String { voices.first?.id ?? "moss-yunshu" }

    let artifact = ModelCatalog.mossTTS
    private(set) var state: State = .notInstalled
    /// Bytes of an interrupted download that a resume will continue from.
    private(set) var partialBytes: Int64 = 0
    /// Space the installed engine occupies on disk.
    private(set) var diskBytes: Int64 = 0
    private(set) var loadSeconds: Double?
    private(set) var preview: Preview = .idle
    private(set) var lastCleanup: LegacyCleanupReport?
    private(set) var lastError: String?
    /// Real syntheses so far (median of the recent ones). Descriptive; it decides the playback lead and nothing else.
    private(set) var synthesis: SynthesisSpeedTracker
    /// Smoothed time from the first word of text to the first audible sound, measured on real answers and previews.
    private(set) var firstAudioMs: Double?

    @ObservationIgnored private var store: ModelStore?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private(set) var speaker: MossNanoSpeaker?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var warming: Task<Void, Never>?
    @ObservationIgnored private var measuring: Task<Void, Never>?
    @ObservationIgnored private var previewOutput: NeuralSpeechOutput?
    @ObservationIgnored private var meter = DownloadSpeedMeter()
    @ObservationIgnored private var activeStreams = 0
    @ObservationIgnored private var extraLead = 0.0
    @ObservationIgnored private let log = Logger(subsystem: "com.italk.assistant", category: "neural-voice")

    init() {
        let defaults = UserDefaults.standard
        for key in Self.obsoleteKeys { defaults.removeObject(forKey: key) }
        let seed = defaults.double(forKey: Self.speedMedianKey)
        synthesis = SynthesisSpeedTracker(seed: seed > 0 ? seed : nil)
        if let bytes = defaults.object(forKey: Self.cleanupKey) as? Int64, bytes > 0 { lastCleanup = LegacyCleanupReport(bytes: bytes, items: 0) }
        migrateSelection()
        guard artifact != nil, let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("iTalk/Voices", isDirectory: true), let s = try? ModelStore(root: root) else { state = .unavailable; return }
        store = s
        self.root = root
        Task { await refresh() }
    }

    // MARK: Selection

    /// The selected voice. A retired id (zf_…/zm_…) resolves to the living voice that replaced it and is rewritten once.
    var voiceID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.voiceKey)
            return LegacyVoiceMigration.resolve(stored: stored, available: Self.voices.map(\.id), fallback: Self.defaultVoice)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.voiceKey) }
    }
    var voiceName: String { Self.displayName(for: voiceID) }
    /// Speaking rate (1.0 = natural). The player time-stretches the engine's audio.
    var speed: Double {
        get { let v = UserDefaults.standard.double(forKey: Self.speedKey); return v == 0 ? 1.0 : v }
        set { UserDefaults.standard.set(newValue, forKey: Self.speedKey) }
    }

    private func migrateSelection() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: Self.voiceKey) else { return }
        let resolved = LegacyVoiceMigration.resolve(stored: stored, available: Self.voices.map(\.id), fallback: Self.defaultVoice)
        if resolved != stored { defaults.set(resolved, forKey: Self.voiceKey) }
    }

    /// Selects a voice and plays it, so the tap is audibly confirmed.
    func select(_ id: String) {
        guard Self.voices.contains(where: { $0.id == id }) else { return }
        voiceID = id
        playPreview(id)
    }

    // MARK: State

    var isInstalled: Bool { state == .installed }
    /// An answer can be spoken: the engine's files are installed and verified.
    var canSpeak: Bool { isInstalled }
    var speedClass: VoiceSpeedClass { VoiceSpeedClass(rtf: synthesis.median) }
    var isSpeaking: Bool { activeStreams > 0 }
    var isDownloading: Bool { if case .downloading = state { true } else if case .verifying = state { true } else { false } }

    /// Deletes what an interrupted download left on the device (the person chose "清除未完成的下载"). Never touches an installed engine or a running download.
    func clearPartialDownload() {
        guard let store, installTask == nil, !isInstalled, !isDownloading else { return }
        Task { [weak self] in
            try? await store.clearPartialDownloads()
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let store, let artifact else { return }
        if case .downloading = state { return }
        if await store.isInstalled(artifact) {
            if await store.validateInstalled(artifact) {
                // The speaker exists before the state says "installed", so an answer never finds an installed engine without a model.
                if speaker == nil, let dir = await store.directory(for: artifact.id) {
                    let moss = MossNanoSpeaker(modelDirectory: dir)
                    for v in MossVoiceLibrary.voices { await moss.register(v) }
                    if speaker == nil { speaker = moss }
                }
                state = .installed
                diskBytes = artifact.totalBytes
                partialBytes = 0
            } else { state = .notInstalled; speaker = nil; diskBytes = 0 }
        } else {
            if state != .verifying { state = .notInstalled }
            speaker = nil; diskBytes = 0
            partialBytes = await store.partialBytes(for: artifact)
        }
        await cleanUpLegacyEngine()
    }

    // MARK: Retired engine

    /// Removes everything the retired Kokoro engine left on disk (weights, voice packs, half-finished downloads) and reports the size once.
    private func cleanUpLegacyEngine() async {
        guard let store, let root else { return }
        var freed: Int64 = 0, items = 0
        for id in LegacyVoiceMigration.artifactIDs {
            if let bytes = try? await store.remove(id) { freed += bytes; items += 1 }
        }
        let fm = FileManager.default
        let modelsDir = root.appendingPathComponent("models", isDirectory: true)
        let legacyDirs = ((try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []).filter {
            let name = $0.lastPathComponent.lowercased()
            return LegacyVoiceMigration.directoryNames.contains(name) || name.hasPrefix("kokoro")
        }
        for dir in legacyDirs {
            freed += Self.directorySize(dir)
            if (try? fm.removeItem(at: dir)) != nil { items += 1 }
        }
        let partial = root.appendingPathComponent("partial", isDirectory: true)
        for dir in ((try? fm.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)) ?? []) where dir.lastPathComponent.lowercased().contains("kokoro") {
            freed += Self.directorySize(dir)
            if (try? fm.removeItem(at: dir)) != nil { items += 1 }
        }
        guard items > 0 else { return }
        lastCleanup = LegacyCleanupReport(bytes: freed, items: items)
        UserDefaults.standard.set(freed, forKey: Self.cleanupKey)
        log.info("removed retired voice engine: \(items, privacy: .public) items, \(freed, privacy: .public) bytes")
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Install, pause, delete

    private func sources(for a: ModelArtifact) async -> [ModelSource] {
        let policy = ModelSourcePolicy(preferMainlandChina: true, allowCandidates: true)
        let probes = await SourceProber.probe(SourcePlanner.order(a, policy: policy), artifact: a, session: .shared)
        return SourcePlanner.order(a, policy: policy, probes: probes)
    }

    func download() {
        guard let store, let artifact, installTask == nil else { return }
        lastError = nil
        meter.reset()
        state = .downloading(DownloadProgress(fraction: Double(partialBytes) / Double(max(artifact.totalBytes, 1)), bytesDone: partialBytes, bytesTotal: artifact.totalBytes))
        installTask = Task { [weak self] in
            guard let self else { return }
            let sources = await self.sources(for: artifact)
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
            let relay: @Sendable (DownloadState) -> Void = { [weak self] event in
                Task { @MainActor in self?.apply(event, to: artifact, names: names) }
            }
            do {
                try await store.install(artifact, sources: sources, onState: relay)
                self.state = .notInstalled
                await self.refresh()
                self.warmUp()
            } catch is CancellationError {
                self.state = .notInstalled
                self.partialBytes = await store.partialBytes(for: artifact)
            } catch ModelStoreError.insufficientStorage(let needed) {
                self.state = .failed("存储空间不足，还需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))。")
            } catch {
                self.state = .failed("下载没有完成，已保留进度，可以稍后继续。")
                self.partialBytes = await store.partialBytes(for: artifact)
            }
            self.installTask = nil
        }
    }

    private func apply(_ event: DownloadState, to artifact: ModelArtifact, names: [String: String]) {
        switch event {
        case .downloading(_, let fraction, let source):
            let bytes = Int64(fraction * Double(artifact.totalBytes))
            meter.update(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
            state = .downloading(DownloadProgress(fraction: fraction, bytesDone: bytes, bytesTotal: artifact.totalBytes, bytesPerSecond: meter.bytesPerSecond,
                                                  secondsRemaining: meter.secondsRemaining(done: bytes, total: artifact.totalBytes), source: names[source] ?? source))
        case .verifying: state = .verifying
        default: break
        }
    }

    /// Stops the download; the bytes already on disk stay and `download()` continues from them.
    func cancelDownload() { installTask?.cancel() }

    /// Removes the engine from the device. Refused while something is being spoken.
    @discardableResult
    func deleteEngine() -> Bool {
        guard let store, let artifact else { return false }
        stopPreview()
        guard activeStreams == 0 else { lastError = "正在朗读，请稍后再删除。"; return false }
        installTask?.cancel(); warming?.cancel(); measuring?.cancel()
        let engine = speaker
        speaker = nil
        state = .notInstalled
        diskBytes = 0
        Task { [weak self] in
            await engine?.unload()
            _ = try? await store.remove(artifact.id)
            try? await store.clearPartialDownloads()
            self?.partialBytes = 0
            self?.loadSeconds = nil
            await self?.refresh()
        }
        return true
    }

    /// Developer/provisioning path: installs the engine from a folder holding the exact manifest files (size- and SHA-256-checked).
    func importEngine(from folder: URL) async throws {
        guard let store, let artifact else { return }
        state = .verifying
        do { try await store.importPackage(artifact, from: folder) } catch { state = .failed("导入失败：\(error.localizedDescription)"); throw error }
        state = .notInstalled
        await refresh()
    }

    // MARK: Preview

    /// Speaks the same Chinese and English sample lines in `id`. Replaces a preview that is still running.
    func playPreview(_ id: String) {
        guard Self.voices.contains(where: { $0.id == id }) else { return }
        stopPreview()
        guard isInstalled else { preview = .failed("请先下载语音引擎，之后就能试听。"); return }
        preview = .preparing(id)
        let output = previewOutput ?? NeuralSpeechOutput(center: self)
        previewOutput = output
        output.voiceOverride = id
        output.begin(onLevel: { _ in }, onFirstAudio: { [weak self] in
            guard let self, self.preview == .preparing(id) else { return }
            self.preview = .playing(id)
        }, completed: { [weak self] ok in
            guard let self, self.preview == .preparing(id) || self.preview == .playing(id) else { return }
            self.preview = ok ? .idle : .failed("没能播放，请再试一次。")
        })
        output.enqueue(VoicePreviewText.chunks)
        output.finishInput()
    }

    func stopPreview() {
        previewOutput?.stop()
        if preview != .idle { preview = .idle }
    }

    // MARK: Loading and speed

    /// Loads the weights ahead of the first answer, so the first sentence is not delayed by Core ML initialization.
    func warmUp() {
        guard isInstalled, let speaker, warming == nil else { return }
        let voice = voiceID
        warming = Task { [weak self] in
            try? await speaker.load(voice: voice)
            self?.loadSeconds = await speaker.loadSeconds
            self?.warming = nil
        }
    }

    /// One short, timed synthesis (after a throw-away warm-up one) when no real measurement exists yet. Foreground and idle only;
    /// it is one more sample, never a gate.
    func measureSpeedIfNeeded() {
        guard isInstalled, let speaker, synthesis.count < 3, measuring == nil, activeStreams == 0, preview == .idle,
              ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        measuring = Task { [weak self] in
            defer { self?.measuring = nil }
            do {
                try await speaker.load(voice: "")
                let voice = self?.voiceID ?? Self.defaultVoice
                for try await _ in speaker.stream("好的。", voice: voice, speed: 1, style: nil) {}      // not counted: first prediction pays one-time costs
                let start = ContinuousClock.now
                var samples = 0
                for try await pcm in speaker.stream("你好，今天过得怎么样？我在这里，有什么需要尽管说。", voice: voice, speed: 1, style: nil) { samples += pcm.count }
                let seconds = Self.seconds(ContinuousClock.now - start), audio = Double(samples) / 48_000
                self?.noteSynthesis(seconds: seconds, audioSeconds: audio)
            } catch { /* try again the next time the page opens */ }
        }
    }

    nonisolated private static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// A finished synthesis (a real sentence or the page's own timing run).
    func noteSynthesis(seconds: Double, audioSeconds: Double) {
        guard audioSeconds > 0, synthesis.record(rtf: seconds / audioSeconds, audioSeconds: audioSeconds), let median = synthesis.median else { return }
        UserDefaults.standard.set(median, forKey: Self.speedMedianKey)
        log.info("voice speed median=\(median, privacy: .public) sample=\(seconds / audioSeconds, privacy: .public) audio=\(audioSeconds, privacy: .public)s")
    }

    func noteFirstAudio(ms: Double) {
        guard ms.isFinite, ms > 0 else { return }
        firstAudioMs = firstAudioMs.map { $0 * 0.7 + ms * 0.3 } ?? ms
    }

    // MARK: Routing and playback lead

    /// The engine and voice for the next answer, or nil when the engine is not installed (the answer then stays text).
    func route(voice override: String? = nil) -> NeuralRoute? {
        guard isInstalled, let speaker else { return nil }
        let chosen = override ?? voiceID
        let voice = Self.voices.contains { $0.id == chosen } ? chosen : Self.defaultVoice
        return NeuralRoute(synth: speaker, voice: voice, speed: Float(speed))
    }

    func streamStarted() { activeStreams += 1 }
    func streamEnded() { activeStreams = max(0, activeStreams - 1) }

    /// Seconds of speech to have queued before the player starts: enough to absorb jitter, more when this device synthesizes slowly.
    func leadSeconds() -> Double { PlaybackLeadPolicy.lead(rtf: synthesis.median, extra: extraLead) }
    /// The queue ran dry mid-answer: start with more lead next time (decays when answers play cleanly).
    func noteUnderrun() { extraLead = min(PlaybackLeadPolicy.maximumExtra, extraLead + 0.25) }
    func noteCleanAnswer() { extraLead = max(0, extraLead - 0.05) }
}
