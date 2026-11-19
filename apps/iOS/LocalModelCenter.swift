import Foundation
import Observation
import UIKit
import BackgroundTasks
import os
import AgentRuntime
import MLXProvider

enum LocalModelState: Equatable {
    case notInstalled
    case downloading(fraction: Double, source: String)
    case verifying
    case installed          // on disk, not loaded
    case loading
    case ready              // weights resident
    case failed(String)
}

/// Owns the on-device model lifecycle (download → verify → load → unload) and runs plain conversation through the shared
/// `AgentRunner`, so local and future cloud providers use the same events, tools and history.
@MainActor @Observable final class LocalModelCenter: LocalChatEngine {
    private(set) var state: LocalModelState = .notInstalled
    private(set) var selected: ModelArtifact
    private(set) var lastMetrics: Usage?
    private(set) var deviceNote: String?
    /// Last source switch during a download (shown under the progress bar). Content of the switch reason is diagnostic only.
    private(set) var sourceNote: String?
    /// Download progress for the UI. Speed is a smoothed average; nil until there is enough data to be honest about it.
    private(set) var downloadedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double?
    var secondsRemaining: Double? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(max(0, selected.totalBytes - downloadedBytes)) / bytesPerSecond
    }
    @ObservationIgnored private var probes: [SourceProbe] = []
    @ObservationIgnored private var speedSample: (bytes: Int64, at: ContinuousClock.Instant)?
    @ObservationIgnored private var continued: AnyObject?          // BGContinuedProcessingTask while a download runs
    let options = ModelCatalog.all

    @ObservationIgnored private var store: ModelStore?
    @ObservationIgnored private var provider: MLXModelProvider?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Unfinished run per conversation. Several conversations may be running at once (the GPU lane serializes local steps).
    private var runs: [UUID: UUID] = [:]
    private var currentRun: UUID? { runs.values.first }
    private(set) var switchingModel = false
    private var preparingRequests = 0
    var localSwitchBlocked: Bool { switchingModel || preparingRequests > 0 || currentRun != nil || state == .loading }
    /// Use the iTalk cloud model (same runner, skills and tools) instead of the on-device model. Chosen in the Model Center.
    private(set) var usesCloud = UserDefaults.standard.bool(forKey: "italk.model.cloud")
    private(set) var selectedCloudId = UserDefaults.standard.string(forKey: "italk.model.cloud.id")
    private(set) var cloudReasoningEffort = UserDefaults.standard.string(forKey: "italk.cloud.reasoning.effort") ?? "none"
    private(set) var cloudModels: [GatewayCloudModel] = []
    /// The gateway client for cloud steps; nil unless the person is signed in with an active subscription (set by `AccountCenter`).
    @ObservationIgnored var cloudClient: (@MainActor () -> CloudClient?)?
    @ObservationIgnored private var cloud: CloudGatewayProvider?
    @ObservationIgnored private var cloudIdentity: (base: URL, modelId: String?, effort: String)?
    /// Once the managed account owns the list, stale updates from the legacy developer gateway are ignored.
    @ObservationIgnored private var managedModels = false
    @ObservationIgnored private var resumedInterrupted = false
    /// Conversation database; context for every turn is built from it (no separate chat history here).
    @ObservationIgnored weak var library: ConversationLibrary?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.italk.assistant", category: "local-model")

    var displayName: String { usesCloud ? (cloudModels.first { $0.id == selectedCloudId }?.name ?? "iTalk 云端模型") : selected.displayName }
    var modelId: String { usesCloud ? selectedCloudId.map { "italk-cloud/" + $0 } ?? "italk-cloud" : selected.id }

    func setManagedCloudModels(_ models: [GatewayCloudModel]) {
        managedModels = true
        applyCloudModels(models)
    }
    func updateCloudModels(_ models: [GatewayCloudModel]) {
        guard !managedModels else { return }
        applyCloudModels(models)
    }
    private func applyCloudModels(_ models: [GatewayCloudModel]) {
        cloudModels = models
        if !models.isEmpty, let id = selectedCloudId, !models.contains(where: { $0.id == id && $0.available }) {
            selectedCloudId = nil
            UserDefaults.standard.removeObject(forKey: "italk.model.cloud.id")
        }
    }
    func selectCloud(_ model: GatewayCloudModel) {
        guard model.available, cloudAvailable, !localSwitchBlocked else { return }
        selectedCloudId = model.id
        UserDefaults.standard.set(model.id, forKey: "italk.model.cloud.id")
        setUsesCloud(true)
    }
    func setCloudReasoningEffort(_ effort: String) {
        guard ["none", "low", "high", "max"].contains(effort), !localSwitchBlocked else { return }
        cloudReasoningEffort = effort
        UserDefaults.standard.set(effort, forKey: "italk.cloud.reasoning.effort")
    }

    func setUsesCloud(_ on: Bool) {
        guard on == usesCloud || !localSwitchBlocked else { return }
        usesCloud = on; UserDefaults.standard.set(on, forKey: "italk.model.cloud")
    }
    var cloudAvailable: Bool { cloudClient?() != nil }
    /// Qwen3.5 artifacts include the vision tower; verified with real inference on a Mac (2026-10-26). iPhone run pending.
    var supportsVision: Bool { usesCloud ? (cloudModels.first { $0.id == selectedCloudId }?.supportsImages ?? false) : localAvailable }
    var localAvailable: Bool { state == .installed || state == .ready || state == .loading }
    var isAvailable: Bool { usesCloud ? cloudAvailable : localAvailable }

    init() {
        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        // 2B needs headroom; phones under ~5.5 GB RAM start with the 0.8B chat-only model.
        selected = ram >= 5_500_000_000 ? ModelCatalog.qwen35_2b_4bit : ModelCatalog.qwen35_0_8b_4bit
        if let saved = UserDefaults.standard.string(forKey: "localModelId"), let match = ModelCatalog.all.first(where: { $0.id == saved }) { selected = match }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("iTalk", isDirectory: true)
            store = try ModelStore(root: support.appendingPathComponent("Models"))
        } catch { state = .failed("无法创建本地存储：\(error.localizedDescription)") }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.unloadForMemory() }
        })
        Task { await refresh() }
    }

    // MARK: Device profile (live values, not constants)

    func deviceProfile() -> DeviceProfile { profile() }
    var modelStore: ModelStore? { store }

    private func profile() -> DeviceProfile {
        let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal; case .fair: .fair; case .serious: .serious; default: .critical }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        // os_proc_available_memory() is 0 where the per-process limit is not enforced (e.g. Simulator): treat as unknown, not as "no memory".
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let reported = Int64(os_proc_available_memory())
        let available = reported > 0 ? reported : physical / 3
        return DeviceProfile(physicalMemory: physical, availableMemory: available,
                             freeDisk: free, thermal: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, metalAvailable: true)
    }

    // MARK: Library

    func refresh() async {
        guard let store else { return }
        if case .downloading = state { return }
        let artifact = selected
        let installed = await store.isInstalled(artifact)
        let valid = installed ? await store.validateInstalled(artifact) : false
        let partial = valid ? 0 : await store.partialBytes(for: artifact)
        guard selected.id == artifact.id, installTask == nil else { return }
        if valid { if state != .ready && state != .loading { state = .installed } }
        else if state != .verifying { state = .notInstalled; downloadedBytes = partial }
    }

    func select(_ artifact: ModelArtifact) {
        // CONTEXT MEMORY
        // Updated: 2026-10-27
        // Status: inferred
        // Why: Selecting another artifact unloads the shared local provider asynchronously.
        // Debug Goal: A switch must not disrupt a running task or expose the old model as ready.
        // Search Tags: local model switch unload active run refresh race
        // Invariants:
        // - A local run and model load finish before the provider can be replaced.
        // - Only the selected artifact may publish its installation state.
        // Failure Modes:
        // - A quick second selection races an unfinished unload.
        // - A slow refresh displays the previous artifact's state.
        guard artifact.id != selected.id, installTask == nil, !localSwitchBlocked else { return }
        switchingModel = true
        selected = artifact
        state = .notInstalled; downloadedBytes = 0
        UserDefaults.standard.set(artifact.id, forKey: "localModelId")
        Task { await unload(); await refresh(); switchingModel = false }
    }

    /// iTalk serves mainland China: domestic mirrors (and the iTalk CDN once configured) first, Hugging Face last.
    /// Every file is hash-checked against the manifest, so a mirror can never install different bytes.
    var policy: ModelSourcePolicy {
        let cdn = (Bundle.main.object(forInfoDictionaryKey: "ITalkModelCDN") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return ModelSourcePolicy(preferMainlandChina: true, allowCandidates: true, cdnBase: cdn)
    }

    func download() {
        guard let store, installTask == nil, !switchingModel else { return }
        if case .refuse(let reason) = ResourceAdvisor.canDownload(selected, profile()) { state = .failed(reason); return }
        let artifact = selected
        state = .downloading(fraction: 0, source: ""); sourceNote = nil
        bytesPerSecond = nil; speedSample = nil
        beginContinuedProcessing(for: artifact)
        installTask = Task { [weak self] in
            guard let self else { return }
            // Quick parallel reachability check so we start with a source that answers from this network.
            self.probes = Array(await SourceProber.probe(SourcePlanner.order(artifact, policy: self.policy), artifact: artifact, session: .shared).values)
            let sources = SourcePlanner.order(artifact, policy: self.policy, probes: Dictionary(uniqueKeysWithValues: self.probes.map { ($0.sourceId, $0) }))
            guard !sources.isEmpty else { self.finishDownload(.failed("网络不可用，请稍后重试")); return }
            let names = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
            let relay: @Sendable (DownloadState) -> Void = { [weak self] event in Task { @MainActor in self?.apply(event, names: names) } }
            do {
                try await store.install(artifact, sources: sources, onState: relay)
                self.finishDownload(.installed)
            } catch is CancellationError {
                self.finishDownload(.notInstalled)
            } catch {
                self.finishDownload(.failed(Self.describe(error)))
            }
        }
    }

    private func finishDownload(_ next: LocalModelState) {
        state = next; sourceNote = nil; bytesPerSecond = nil; installTask = nil
        if case .installed = next { downloadedBytes = selected.totalBytes }
        else if let store { Task { downloadedBytes = await store.partialBytes(for: selected) } }
        if let task = continued as? BGContinuedProcessingTask { task.setTaskCompleted(success: next == .installed) }
        continued = nil
    }

    private func apply(_ event: DownloadState, names: [String: String]) {
        switch event {
        case .downloading(_, let f, let src):
            let total = selected.totalBytes
            downloadedBytes = Int64(f * Double(total))
            state = .downloading(fraction: f, source: names[src] ?? src)
            let now = ContinuousClock.now
            if let s = speedSample {
                let dt = (now - s.at).components
                let seconds = Double(dt.seconds) + Double(dt.attoseconds) / 1e18
                if seconds >= 1 {
                    let instant = Double(downloadedBytes - s.bytes) / seconds
                    bytesPerSecond = instant < 0 ? nil : bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
                    speedSample = (downloadedBytes, now)
                }
            } else { speedSample = (downloadedBytes, now) }
            if let task = continued as? BGContinuedProcessingTask {
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = downloadedBytes
            }
        case .switchingSource: sourceNote = "已切换下载线路"
        case .verifying: state = .verifying
        default: break
        }
    }

    /// iOS 26: keeps a user-started download running after the app is left; the system shows its own progress UI.
    /// No special entitlement is needed (only the permitted identifier in Info.plist). If the system declines or expires
    /// the task, the download pauses and the .part file resumes later.
    ///
    /// Each download registers its own concrete identifier right before submitting: on iOS 26 a handler registered for the
    /// wildcard pattern is not matched to concrete identifiers, and `submit` then raises an Objective-C exception that
    /// kills the app (Apple forum thread 799126; reproduced on device 2026-10-26). If registration fails we never submit:
    /// the download simply continues in the foreground.
    private static let continuedPrefix = "com.italk.assistant.model-download"
    private func beginContinuedProcessing(for artifact: ModelArtifact) {
        let identifier = "\(Self.continuedPrefix).\(UUID().uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                task.progress.totalUnitCount = artifact.totalBytes
                task.progress.completedUnitCount = self.downloadedBytes
                task.expirationHandler = { [weak self] in Task { @MainActor in self?.installTask?.cancel() } }
                if self.installTask == nil { task.setTaskCompleted(success: self.state == .installed) } else { self.continued = task }
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "正在下载本地模型", subtitle: artifact.displayName)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { /* system declined: foreground download continues */ }
    }

    func cancelDownload() { installTask?.cancel() }

    func remove() {
        guard let store, !localSwitchBlocked else { return }
        Task {
            cancel(); await unload()
            _ = try? await store.remove(selected.id)
            await refresh()
        }
    }

    // MARK: Loading

    private func ensureLoaded() async throws {
        #if targetEnvironment(simulator)
        // MLX's Metal kernels crash the process on the iOS Simulator (reproduced with the same model in a bare test target).
        throw AppFailure.message("iOS 模拟器不支持本地模型的 GPU 推理，请在真机上运行。")
        #else
        if state == .ready, provider != nil { return }
        guard let store, let dir = await store.directory(for: selected.id) else { throw AppFailure.message("本地模型尚未下载。请在设置中下载。") }
        let p = profile()
        switch ResourceAdvisor.canRun(selected, p) {
        case .refuse(let reason): throw AppFailure.message(reason)
        case .degraded(_, let reason): deviceNote = reason
        case .ok: deviceNote = nil
        }
        state = .loading
        // Thermal / Low Power Mode can lower (never raise) the autonomy the catalog earned.
        var artifact = selected
        artifact.maxAutonomy = ResourceAdvisor.effectiveAutonomy(selected, p)
        let provider = MLXModelProvider(artifact: artifact, directory: dir)
        do { try await provider.prepare { _ in } }
        catch { state = .installed; throw AppFailure.message("本地模型载入失败，请重试；若反复失败，请在设置中删除后重新下载。") }
        self.provider = provider
        state = .ready
        #endif
    }

    /// Load weights ahead of the first question (also used by the developer benchmark to time loading separately).
    func preload() async throws { try await ensureLoaded() }

    func unload() async {
        await provider?.unload(); provider = nil
        if state == .ready || state == .loading { state = .installed }
    }

    private func unloadForMemory() async {
        guard currentRun == nil else { return }   // never tear down a generation mid-answer; iOS will still reclaim if needed
        await unload()
    }

    // MARK: LocalChatEngine

    /// The model the next step runs on: the on-device model, or the cloud model when chosen and consented.
    func activeProvider() async throws -> any ModelProvider {
        if usesCloud {
            guard let client = cloudClient?() else { throw AppFailure.message("云端模型需要登录并订阅。可在模型中心切换回本地模型。") }
            let chosen = cloudModels.first { $0.id == selectedCloudId && $0.available } ?? cloudModels.first { $0.available }
            guard let chosen else { throw AppFailure.message("当前订阅没有可用的云端模型。可在模型中心切换回本地模型。") }
            if cloud == nil || cloudIdentity?.base != client.baseURL || cloudIdentity?.modelId != chosen.id || cloudIdentity?.effort != cloudReasoningEffort {
                cloud = CloudGatewayProvider(client: client, modelName: chosen.name, modelId: chosen.id, reasoningEffort: cloudReasoningEffort, vision: chosen.supportsImages)
                cloudIdentity = (client.baseURL, chosen.id, cloudReasoningEffort)
            }
            return cloud!
        }
        // A turn committed while the phone is locked (voice session in the background) waits for the app to return:
        // iOS terminates on-device GPU work in the background.
        while UIApplication.shared.applicationState == .background {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
        }
        try await ensureLoaded()
        guard let provider else { throw AppFailure.message("本地模型未就绪。") }
        return provider
    }

    /// Answers the latest user message of `conversationId` through the shared agent runner. The run belongs to the
    /// conversation, not to this call: if the caller stops waiting (conversation switch, leaving the screen) the run keeps
    /// going and `AgentPlatform` writes its result to the conversation. Approval cards keep it waiting, not failing.
    func respond(conversationId: UUID, turnId: UUID, voice: Bool, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        preparingRequests += 1
        defer { preparingRequests -= 1 }
        let provider = try await activeProvider()
        guard let library, let runner = await AgentPlatform.shared.runner(using: provider) else { throw AppFailure.message("对话存储暂不可用。") }
        let caps = provider.descriptor.capabilities
        // Voice: prefill time is time-to-first-word, so keep the spoken context small (summary + the last few turns).
        let budget = voice ? ContextBudget(contextWindow: min(caps.contextWindow, 3072), reservedOutput: 256, reservedTools: 900)
                           : ContextBudget(contextWindow: caps.contextWindow, reservedOutput: 512, reservedTools: 1200)
        let summarizer: (any ContextSummarizer)? = ProviderSummarizer(provider: provider)
        let built = try await library.context.build(conversationId: conversationId, budget: budget, supportsVision: caps.visionInput,
                                                    summarizer: summarizer, modelId: modelId)
        library.noteContext(built.status)
        var context = built.messages
        while let last = context.last, last.role == .assistant, last.text.isEmpty { context.removeLast() }
        // Learn from the person's own words first, so a correction ("不对，我搬到上海了") already applies to this very answer.
        if let said = context.last(where: { $0.role == .user })?.text, let learn = AgentPlatform.shared.memoryHooks?.learn { await learn(said, conversationId) }
        if !resumedInterrupted { resumedInterrupted = true; await AgentPlatform.shared.resumeInterrupted() }
        // A new message supersedes an unfinished run of this conversation (e.g. one still waiting for a confirmation).
        if let old = runs.removeValue(forKey: conversationId) { await runner.cancel(old) }
        let events = await runner.bus.subscribe()
        // When a step's prompt is still too big for the window, the runner asks for the history again at a smaller size. That goes through the same
        // summaries (persisted, reused next turn) instead of dropping turns; the budget here is the room the runner measured, not a fraction of the window.
        let context_ = library.context, supportsVision = caps.visionInput
        let rebuild: AgentRunner.HistoryRebuilder = { room in
            var tight = ContextBudget(contextWindow: max(256, room), reservedOutput: 0, reservedTools: 0)
            tight.safetyFraction = 1.0
            guard let again = try? await context_.build(conversationId: conversationId, budget: tight, supportsVision: supportsVision, summarizer: nil, modelId: nil) else { return nil }
            var rebuilt = again.messages
            while let last = rebuilt.last, last.role == .assistant, last.text.isEmpty { rebuilt.removeLast() }
            return rebuilt
        }
        let runId: UUID
        do {
            runId = try await runner.start(conversationId: conversationId, context: context, source: voice ? "voice" : "text", tag: turnId.uuidString, historyRebuilder: rebuild)
        } catch RunnerError.conversationBusy {
            throw AppFailure.message("上一条回答仍在结束，请稍后重试。")
        } catch RunnerError.unknownRun {
            throw AppFailure.message("无法读取这条消息的对话上下文，请重新发送。")
        } catch RunnerError.noProvider {
            throw AppFailure.message("当前模型尚未准备好，请稍后重试。")
        }
        runs[conversationId] = runId
        AgentPlatform.shared.bind(runId: runId, turnId: turnId)
        defer { if runs[conversationId] == runId { runs[conversationId] = nil } }
        // Streams the current model step. Tool steps arrive
        // separately through AgentPlatform.steps. Waits through confirmations until the run ends.
        let relay = Task { @MainActor () -> AgentEventType? in
            var shown = ""
            for await e in events where e.runId == runId {
                switch (e.type, e.payload) {
                case (.modelStarted, _):
                    shown = ""
                    if e.stepId != "model-1" { onText("") }
                case (.modelDelta, .textDelta(let d)):
                    shown += d
                    onText(shown)
                case (.runState, .state(_, let to, _)) where to == .awaitingNetwork: return .runSuspended
                default: break
                }
                if [.runCompleted, .runFailed, .runCancelled].contains(e.type) { return e.type }
            }
            return nil
        }
        let ended = await relay.value
        guard let snapshot = await runner.snapshot(runId) else { throw CancellationError() }
        lastMetrics = snapshot.usage.last
        if ended == .runSuspended { throw AppFailure.message("网络中断，已暂停；恢复联网后会自动继续这条回答。") }
        switch snapshot.state {
        case .completed:
            let answer = AgentPlatform.answerText(snapshot)
            guard !answer.isEmpty else { throw AppFailure.message("模型没有生成回答，请换个说法再试。") }
            for r in snapshot.contextReports ?? [] where r.kind == "step" && (!r.attempts.isEmpty || r.headroom < 256) {
                log.info("context step=\(r.step, privacy: .public) window=\(r.window, privacy: .public) prompt=\(r.promptTokens, privacy: .public) exact=\(r.exact, privacy: .public) room=\(r.reservedOutput, privacy: .public) skills=\(r.skillTokens, privacy: .public) history=\(r.historyTokens, privacy: .public) attempts=\(r.attempts.joined(separator: ","), privacy: .public)")
            }
            if let u = snapshot.usage.last {
                log.info("run ttft=\(u.firstTokenLatency ?? -1, privacy: .public) tps=\(u.tokensPerSecond ?? -1, privacy: .public) prompt=\(u.promptTokens, privacy: .public) tools=\(snapshot.toolCalls, privacy: .public) skills=\(snapshot.loadedSkills.joined(separator: ","), privacy: .public)")
            }
            return answer
        case .cancelled: throw CancellationError()
        case .expired: throw AppFailure.message("确认已过期，操作没有执行。")
        default:
            if snapshot.failure == "context_too_large" { log.error("context_too_large \(snapshot.failureDetail ?? "", privacy: .public)") }
            throw AppFailure.message(Self.explain(snapshot.failure ?? snapshot.state.rawValue, cloud: usesCloud))
        }
    }

    /// Every failure ends in a sentence the person can act on.
    static func explain(_ reason: String, cloud: Bool) -> String {
        switch reason {
        case "tool_loop": "模型反复调用同一个工具，已停止，操作可能没有完成。请换用更强的模型或调整请求后重试。"
        case "repetitive_output": "模型反复输出相同内容，已停止生成。这次回答没有完成，请重试或切换模型。"
        case "budget_exhausted", "tool_budget_exhausted": "这个任务步骤太多，已停止。可以把它拆成小一点的请求再试。"
        case "context_too_large": "这次内容太长，当前模型一次放不下。可以缩短内容、分段发送，或在模型中心换用上下文更长的模型。"
        case "empty_answer": "模型没有给出回答。可以换个说法再试一次，或在模型中心换用更大的模型。"
        case "unauthorized": "登录已过期，请在设置中重新登录。"
        case "subscription_required": "云端模型需要订阅。可在设置 › iTalk 云端 中查看，或切换回本地模型。"
        case "quota_exceeded": "本周或本订阅周期的云端用量已用完。额度重置后再试，或切换回本地模型。"
        case "too_many_concurrent_requests": "同时进行的云端请求过多，请稍后再试。"
        case "model_not_in_plan": "当前订阅不包含这个云端模型。"
        case "interrupted": "云端服务重启，这次回答被中断，请重试。"
        case "credit_insufficient", "insufficient_credits": "云端可用额度不足，请在“账户与用量”中查看余额。"
        case "cloud_consent_required", "image_consent_required", "health_consent_required": "这次请求尚未获得云端处理授权，请在模型中心检查授权后重试。"
        case "model_not_available", "provider_not_configured": "当前服务没有开放所选云端模型，请刷新模型中心或切换回本地模型。"
        case "invalid_arguments": "云端服务与 App 请求版本不匹配。请重开 App 后重试；若仍失败，请更新服务。"
        case "turn_in_progress": "上一条云端请求仍在处理中，请稍后再试。"
        case "provider_request_failed": "DeepSeek 上游服务未完成请求，请检查服务端模型额度或稍后重试。"
        case "provider_incomplete", "provider_usage_unavailable": "云端回答中断，本次用量尚未确认。请稍后重试。"
        case "rate_limit": "云端请求较频繁，请稍等片刻再试。"
        case "provider_error": cloud ? "云端请求未完成。请稍后重试，或切换回本地模型。" : "本地模型出错了，请重试；反复出现请重启 App。"
        default: "出错了（\(reason)），请重试。"
        }
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-31
    // Status: inferred
    // Why: Runner cancellation is asynchronous, and a retry can start before it completes.
    // Debug Goal: Keep the old run discoverable until cancellation so the next turn can await it.
    // Search Tags: stop retry conversation busy cancellation race
    // Invariants:
    // - Cleanup must not erase a newer run for the same conversation.
    // - Tool side effects already in flight are still journaled.
    // Failure Modes:
    // - Removing the mapping before cancellation makes a quick retry hit conversationBusy.
    // - Old cancellation cleanup clears the new run's mapping.
    /// Explicit stop: cancels the conversation's run immediately (tool side effects in flight still finish and are journaled).
    func cancel() {
        guard let runner = AgentPlatform.shared.currentRunner else { return }
        let pending = runs
        Task {
            for (conversation, id) in pending {
                await runner.cancel(id)
                if runs[conversation] == id { runs[conversation] = nil }
            }
        }
    }
    func cancel(conversationId: UUID) {
        guard let runner = AgentPlatform.shared.currentRunner, let id = runs[conversationId] else { return }
        Task {
            await runner.cancel(id)
            if runs[conversationId] == id { runs[conversationId] = nil }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ModelStoreError.integrityFailure, ModelStoreError.sizeMismatch: "文件校验失败，请重试"
        case ModelStoreError.allSourcesFailed: "网络不稳定，已暂停"
        case ModelStoreError.insufficientStorage(let n): "存储空间不足，还需约 \(n / 1_000_000) MB"
        case ModelStoreError.noSources: "网络不可用，请稍后重试"
        default: error.localizedDescription
        }
    }
}
