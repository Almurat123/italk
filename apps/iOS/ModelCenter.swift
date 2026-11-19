import Foundation
import Observation
import AgentRuntime

/// UI-facing model library: every downloadable model and voice with its own install state. Browsing, downloading or deleting
/// one entry never changes the model a conversation is using; only `select` does, and only when nothing is running.
///
/// Language models: the selected artifact's lifecycle is owned by `LocalModelCenter`; any other artifact downloads through this
/// class with the same verified, multi-source `ModelStore`. Voices are owned by `NeuralVoiceCenter`.
@MainActor @Observable final class ModelCenter {
    private(set) var installedIds: Set<String> = []
    private(set) var partialBytes: [String: Int64] = [:]
    /// Downloads of language models other than the selected one.
    private(set) var background: [String: ModelInstallState] = [:]
    private(set) var lastError: [String: String] = [:]

    @ObservationIgnored private let local: LocalModelCenter
    @ObservationIgnored private let voices: NeuralVoiceCenter
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var samples: [String: (bytes: Int64, at: ContinuousClock.Instant, bps: Double?)] = [:]
    @ObservationIgnored private let cards = Dictionary(uniqueKeysWithValues: ModelCenterCatalog.cards().map { ($0.id, $0) })
    /// The voice engine (one set of weights shared by every voice).
    static let mossBaseId = "moss-tts-nano-100m-coreml"

    init(local: LocalModelCenter, voices: NeuralVoiceCenter) { self.local = local; self.voices = voices }

    // MARK: Entries

    var entries: [ModelEntry] { languageEntries + voiceEntries }
    var languageModels: [ModelEntry] { languageEntries }
    var voiceModels: [ModelEntry] { voiceEntries }
    func entry(_ id: String) -> ModelEntry? { entries.first { $0.id == id } }

    private var languageEntries: [ModelEntry] {
        let busy = local.localSwitchBlocked ? "有对话正在进行。完成后才能切换或删除模型。" : nil
        return ModelCatalog.all.map { a in
            ModelEntry(id: a.id, kind: .languageModel, name: a.displayName, subtitle: Self.languageSubtitle(a), state: state(of: a),
                       totalBytes: a.totalBytes, isActive: !local.usesCloud && local.selected.id == a.id,
                       busyReason: local.selected.id == a.id || installedIds.contains(a.id) ? busy : nil, card: cards[a.id])
        }
    }

    private var voiceEntries: [ModelEntry] {
        guard let engine = voices.artifact else { return [] }
        let st: ModelInstallState = switch voices.state {
        case .unavailable: .failed("此设备暂不支持设备端语音。")
        case .notInstalled: voices.partialBytes > 0 ? .partial(bytesDone: voices.partialBytes) : .notInstalled
        case .downloading(let progress): .downloading(progress)
        case .verifying: .verifying
        case .installed: .installed
        case .failed(let message): .failed(message)
        }
        var note = "中文与英文同一个声音 · 离线合成"
        if let rtf = voices.synthesis.median, voices.isInstalled { note += String(format: " · 本机合成约 %.1f 倍实时", 1 / max(rtf, 0.01)) }
        var out = [ModelEntry(id: Self.mossBaseId, kind: .voiceBase, name: "语音引擎（MOSS-TTS-Nano）", subtitle: note, state: st, totalBytes: engine.totalBytes,
                              isActive: voices.isInstalled, busyReason: voices.isSpeaking ? "正在朗读，结束后才能删除。" : nil)]
        for v in NeuralVoiceCenter.voices {
            out.append(ModelEntry(id: v.id, kind: .voicePack, name: v.name, subtitle: v.note + (v.gender == .male ? " · 男声" : " · 女声"),
                                  state: voices.isInstalled ? .installed : .notInstalled, totalBytes: 0,
                                  isActive: voices.voiceID == v.id, requiresBase: Self.mossBaseId))
        }
        return out
    }

    private func state(of a: ModelArtifact) -> ModelInstallState {
        if local.selected.id == a.id {
            switch local.state {
            case .notInstalled: return local.downloadedBytes > 0 ? .partial(bytesDone: local.downloadedBytes) : (lastError[a.id].map { .failed($0) } ?? .notInstalled)
            case .downloading(let f, let source):
                return .downloading(DownloadProgress(fraction: f, bytesDone: local.downloadedBytes, bytesTotal: a.totalBytes,
                                                     bytesPerSecond: local.bytesPerSecond, secondsRemaining: local.secondsRemaining, source: source.isEmpty ? nil : source))
            case .verifying: return .verifying
            case .installed: return .installed
            case .loading: return .loading
            case .ready: return .loaded
            case .failed(let m): return .failed(m)
            }
        }
        if let b = background[a.id] { return b }
        if installedIds.contains(a.id) { return .installed }
        if let m = lastError[a.id] { return .failed(m) }
        if let p = partialBytes[a.id], p > 0 { return .partial(bytesDone: p) }
        return .notInstalled
    }

    private static func languageSubtitle(_ a: ModelArtifact) -> String {
        let gb = Double(a.totalBytes) / 1_000_000_000
        return String(format: "设备端 · 约 %.1f GB · %d 万 tokens 上下文", gb, max(1, a.contextTokens / 10_000))
    }

    // MARK: Refresh

    func refresh() async {
        guard let store = local.modelStore else { return }
        var ids = Set<String>(), part: [String: Int64] = [:]
        for a in ModelCatalog.all {
            if await store.isInstalled(a), await store.validateInstalled(a) { ids.insert(a.id) }
            else { part[a.id] = await store.partialBytes(for: a) }
        }
        installedIds = ids; partialBytes = part
        await local.refresh()
        await voices.refresh()
    }

    // MARK: Operations (each acts on exactly the entry it names)

    func download(_ id: String) {
        lastError[id] = nil
        if id == Self.mossBaseId || NeuralVoiceCenter.voices.contains(where: { $0.id == id }) { voices.download(); return }
        guard let a = ModelCatalog.all.first(where: { $0.id == id }) else { return }
        if local.selected.id == a.id { local.download() } else { startBackground(a) }
    }

    /// Stops a download. Bytes already on disk stay, so `download` resumes from them.
    func pause(_ id: String) {
        if id == Self.mossBaseId || NeuralVoiceCenter.voices.contains(where: { $0.id == id }) { voices.cancelDownload(); return }
        if local.selected.id == id { local.cancelDownload() } else { tasks[id]?.cancel() }
    }

    func resume(_ id: String) { download(id) }

    func delete(_ id: String) {
        if id == Self.mossBaseId { voices.deleteEngine(); return }
        guard let a = ModelCatalog.all.first(where: { $0.id == id }) else { return }
        if local.selected.id == a.id { local.remove(); Task { try? await Task.sleep(for: .seconds(1)); await refresh() }; return }
        guard let store = local.modelStore, !local.localSwitchBlocked else { return }
        tasks[id]?.cancel()
        Task { _ = try? await store.remove(a.id); await refresh() }
    }

    /// Makes an installed language model (or an installed voice) the one used from now on.
    @discardableResult func select(_ id: String) -> Bool {
        if let v = NeuralVoiceCenter.voices.first(where: { $0.id == id }) { voices.select(v.id); return true }
        guard let a = ModelCatalog.all.first(where: { $0.id == id }), installedIds.contains(id) || local.selected.id == id, !local.localSwitchBlocked else { return false }
        local.setUsesCloud(false); local.select(a); return true
    }

    // MARK: Background language-model downloads

    private func startBackground(_ a: ModelArtifact) {
        guard let store = local.modelStore, tasks[a.id] == nil else { return }
        if case .refuse(let reason) = ResourceAdvisor.canDownload(a, local.deviceProfile()) { background[a.id] = .failed(reason); return }
        background[a.id] = .downloading(DownloadProgress(fraction: 0, bytesDone: 0, bytesTotal: a.totalBytes))
        let policy = local.policy
        tasks[a.id] = Task { [weak self] in
            guard let self else { return }
            let probes = await SourceProber.probe(SourcePlanner.order(a, policy: policy), artifact: a, session: .shared)
            let sources = SourcePlanner.order(a, policy: policy, probes: probes)
            guard !sources.isEmpty else { self.finish(a.id, error: "网络不可用，请稍后重试"); return }
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
            let relay: @Sendable (DownloadState) -> Void = { [weak self] e in Task { @MainActor in self?.apply(e, to: a, names: names) } }
            do { try await store.install(a, sources: sources, onState: relay); self.finish(a.id, error: nil) }
            catch is CancellationError { self.finish(a.id, error: nil) }
            catch ModelStoreError.insufficientStorage(let n) { self.finish(a.id, error: "存储空间不足，还需约 \(n / 1_000_000) MB") }
            catch ModelStoreError.allSourcesFailed { self.finish(a.id, error: "网络不稳定，已暂停；可稍后继续") }
            catch { self.finish(a.id, error: "下载未完成：\(error.localizedDescription)") }
        }
    }

    private func apply(_ e: DownloadState, to a: ModelArtifact, names: [String: String]) {
        switch e {
        case .downloading(_, let f, let src):
            let bytes = Int64(f * Double(a.totalBytes))
            var bps = samples[a.id]?.bps
            let now = ContinuousClock.now
            if let s = samples[a.id] {
                let d = (now - s.at).components
                let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
                if seconds >= 1 {
                    let instant = Double(bytes - s.bytes) / seconds
                    bps = instant < 0 ? nil : (s.bps.map { $0 * 0.7 + instant * 0.3 } ?? instant)
                    samples[a.id] = (bytes, now, bps)
                }
            } else { samples[a.id] = (bytes, now, nil) }
            let remaining = bps.flatMap { $0 > 0 ? Double(max(0, a.totalBytes - bytes)) / $0 : nil }
            background[a.id] = .downloading(DownloadProgress(fraction: f, bytesDone: bytes, bytesTotal: a.totalBytes, bytesPerSecond: bps,
                                                             secondsRemaining: remaining, source: names[src] ?? src))
        case .verifying: background[a.id] = .verifying
        default: break
        }
    }

    private func finish(_ id: String, error: String?) {
        tasks[id] = nil; background[id] = nil; samples[id] = nil
        if let error { lastError[id] = error }
        Task { await refresh() }
    }
}
