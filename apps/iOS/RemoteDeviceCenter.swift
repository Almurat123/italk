import Foundation
import Observation
import UIKit
import os
import AgentRuntime
import RemoteAgent

/// The person's own computers as Agent nodes. The computer owns its models, tools, files, credentials and tasks; the phone pairs with it by QR code,
/// sends prompts and approvals, and shows only what the computer reports. Tasks keep running on the computer when the phone sleeps or leaves the
/// network: the computer keeps a durable event log and the phone resumes reading it from the last event it saw (Packages/RemoteAgent).
///
/// Nothing is simulated. If a computer is asleep or unreachable its state says so, and a task that was running when contact was lost is shown as
/// `.lost` (outcome unknown) until the computer answers again.
@MainActor @Observable final class RemoteDeviceCenter {
    private(set) var devices: [RemoteDeviceInfo] = []
    private(set) var pairing: PairingState = .idle
    /// Pairing and tasks work in this build.
    private(set) var isSupported = true
    /// Short plain-language reason when `isSupported` is false.
    private(set) var unsupportedReason = ""
    /// Everything each task has done so far (text, reasoning, tool steps, approvals), keyed by task id. Rebuilt from the computer's log on demand.
    private(set) var transcripts: [String: RemoteTranscript] = [:]
    /// What each computer last reported about itself (agents, models, limits).
    private(set) var statuses: [String: AgentStatus] = [:]

    /// Whether a computer can think: it reasons only through iTalk's gateway, with a credential this phone hands over after pairing.
    enum AccessState: Equatable, Sendable {
        case unknown
        /// The computer is paired but has no model access yet.
        case notConfigured
        /// The phone is handing the access over right now.
        case providing
        case ready(models: [CloudModel], plan: String?)
        /// Something the person can act on, in plain words; `code` is stable for the UI.
        case problem(code: String, message: String)
        var isReady: Bool { if case .ready = self { true } else { false } }
    }
    private(set) var access: [String: AccessState] = [:]
    /// Tools, skills and project instructions each computer reported (`GET /v1/capabilities`).
    private(set) var capabilities: [String: AgentCapabilities] = [:]
    /// Set by the app so the phone can request a credential for a computer from the person's own account.
    @ObservationIgnored weak var account: AccountCenter?
    @ObservationIgnored private var provisionAttempts: [String: Int] = [:]

    var onlineCount: Int { devices.filter { $0.state.isOnline }.count }
    var hasDevices: Bool { !devices.isEmpty }
    func device(_ id: String) -> RemoteDeviceInfo? { devices.first { $0.id == id } }
    var allTasks: [RemoteTaskInfo] { devices.flatMap(\.tasks).sorted { $0.updatedAt > $1.updatedAt } }
    func transcript(for taskId: String) -> RemoteTranscript? { transcripts[taskId] }

    @ObservationIgnored private var computers: [String: StoredComputer] = [:]
    @ObservationIgnored private var clients: [String: RemoteAgentClient] = [:]
    @ObservationIgnored private var connection: [String: RemoteConnectionState] = [:]
    @ObservationIgnored private var unreachableSince: [String: Date] = [:]
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingByTask: [String: RemoteApprovalRequest] = [:]
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    /// Computers a refresh is already talking to, so the page, the supervisor and a button never pile requests on the same Mac.
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let secrets = KeychainRemoteSecrets()
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let log = Logger(subsystem: "com.italk.assistant", category: "remote")

    init(storeURL: URL? = nil) {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.storeURL = storeURL ?? (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("remote-computers.json")
        load()
        rebuild()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startSupervising(); await self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendWatching(); self?.stopSupervising() }
        })
        startSupervising()
        Task { await refresh() }
    }

    // MARK: Staying in touch

    /// While the app is in front, a computer that is not connected is tried again with a growing pause (3, 6, 12, 24, then every 30 s) and a connected one is
    /// checked every 30 s, so what the person sees is never stale and a Mac that wakes up or restarts is picked up without a tap.
    private func startSupervising() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in
            var due: [String: Date] = [:], misses: [String: Int] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                for id in Array(self.computers.keys) where (due[id] ?? .distantPast) <= now && !self.inFlight.contains(id) {
                    await self.refreshOne(id, quiet: true)
                    self.rebuild()
                    let state = self.connection[id]
                    if state?.isOnline == true { misses[id] = 0; due[id] = Date().addingTimeInterval(30) }
                    else if case .some(.revoked) = state { due[id] = Date().addingTimeInterval(60) }
                    else { let n = (misses[id] ?? 0) + 1; misses[id] = n; due[id] = Date().addingTimeInterval(min(30, 3 * pow(2, Double(n - 1)))) }
                }
                for id in due.keys where self.computers[id] == nil { due[id] = nil; misses[id] = nil }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopSupervising() { supervisor?.cancel(); supervisor = nil }

    // MARK: Pairing (QR payload scanned from the computer's terminal)

    func beginPairing(payload: String) async {
        pairingTask?.cancel()
        let task = Task { await runPairing(payload: payload) }
        pairingTask = task
        await task.value
    }

    private func runPairing(payload: String) async {
        let link: RemotePairingLink
        do { link = try RemotePairingLink(parsing: payload) }
        catch RemotePairingLink.ParseError.unsupportedVersion { pairing = .failed(.protocolMismatch); return }
        catch { pairing = .failed(.invalidCode); return }
        guard let identity = identity() else { pairing = .failed(.protocolMismatch); return }
        pairing = .connecting
        do {
            let record = try await RemotePairing.pair(link: link, identity: identity, phoneName: Self.phoneName()) { [weak self] stage in
                Task { @MainActor in
                    guard let self, self.pairingTask != nil else { return }
                    if case .awaitingApprovalOnComputer(let fp) = stage, case .connecting = self.pairing { self.pairing = .awaitingApprovalOnComputer(fingerprint: fp) }
                }
            }
            if Task.isCancelled { pairing = .failed(.cancelled); return }
            computers[record.id] = StoredComputer(record: record, alias: computers[record.id]?.alias, lastSeen: Date(), tasks: [], status: nil)
            clients[record.id]?.invalidate(); clients[record.id] = RemoteAgentClient(record: record, identity: identity)
            connection[record.id] = .connecting
            save(); rebuild()
            pairing = .paired(deviceId: record.id)
            await refresh(only: record.id)
            await provisionAccess(deviceId: record.id)
        } catch let error as PairingError {
            pairing = .failed(error.failure)
        } catch is CancellationError {
            pairing = .failed(.cancelled)
        } catch { pairing = .failed(.unreachable) }
    }

    func cancelPairing() { pairingTask?.cancel(); pairingTask = nil; pairing = .idle }
    func resetPairingState() { pairing = .idle }

    // MARK: Device management

    func rename(_ deviceId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        computers[deviceId]?.alias = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        save(); rebuild()
    }

    /// The computer revokes its shared cloud credential when its last paired phone is removed.
    /// If it is offline, revoke this phone on the computer or remove its session in the account later.
    func revoke(_ deviceId: String) async {
        let client = clients[deviceId]
        if let client { try? await client.unpair(); await client.invalidate() }
        for t in computers[deviceId]?.tasks ?? [] { watchers[t.id]?.cancel(); watchers[t.id] = nil; transcripts[t.id] = nil; pendingByTask[t.id] = nil }
        computers[deviceId] = nil; clients[deviceId] = nil; connection[deviceId] = nil; unreachableSince[deviceId] = nil; statuses[deviceId] = nil; access[deviceId] = nil; capabilities[deviceId] = nil; provisionAttempts[deviceId] = nil
        save(); rebuild()
    }

    func reconnect(_ deviceId: String) async { await refresh(only: deviceId) }
    func refresh() async { await refresh(only: nil) }

    // MARK: Tasks

    struct TaskOptions: Sendable {
        var workingFolder: String?
        /// "readOnly", "ask" (default), "acceptEdits" or "auto". The computer lowers it to the highest mode its owner allows.
        var permissionMode: String = "ask"
        var continuing: String?
        var title: String?
        var history: [NewRemoteTask.Turn] = []
        var idempotencyKey: String?
        var sharedMemory: [String] = []
    }

    /// `modelId` is `"<agent>"` or `"<agent>/<model>"` as listed in `RemoteDeviceInfo.models`; nil picks the first agent that is ready.
    func submitTask(deviceId: String, prompt: String, modelId: String?) async throws -> RemoteTaskInfo {
        try await submitTask(deviceId: deviceId, prompt: prompt, modelId: modelId, options: TaskOptions())
    }

    func submitTask(deviceId: String, prompt: String, modelId: String?, options: TaskOptions) async throws -> RemoteTaskInfo {
        guard let client = clients[deviceId], let status = statuses[deviceId] ?? computers[deviceId]?.status else { throw RemoteUnavailable() }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteError.http(status: 400, code: "invalid_arguments") }
        let (backend, model) = Self.resolve(modelId, in: status)
        guard let backend else { throw RemoteError.http(status: 400, code: "backend_not_available") }
        let request = NewRemoteTask(backend: backend, prompt: text, history: options.history.isEmpty ? nil : options.history, model: model, cwd: options.workingFolder,
                                    permissionMode: options.permissionMode, continueTaskId: options.continuing, title: options.title,
                                    sharedMemory: options.sharedMemory.isEmpty ? nil : options.sharedMemory)
        // One key per submission: a retry after a lost reply returns the same task instead of running it twice.
        let key = options.idempotencyKey ?? ("ios-" + UUID().uuidString)
        var lastError: Error = RemoteError.unreachable
        for attempt in 0..<3 {
            do {
                let snapshot = try await client.createTask(request, idempotencyKey: key)
                connection[deviceId] = .connected; unreachableSince[deviceId] = nil
                upsert(snapshot, on: deviceId)
                transcripts[snapshot.id] = RemoteTranscript()
                watch(snapshot.id, on: deviceId)
                rebuild()
                return taskInfo(snapshot, deviceId: deviceId, lost: false)
            } catch let error as RemoteError {
                lastError = error
                guard error == .unreachable else { throw error }
                try? await Task.sleep(for: .seconds(1 + Double(attempt)))
            }
        }
        markUnreachable(deviceId)
        throw lastError
    }

    func cancelTask(_ taskId: String) async {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { return }
        if let snapshot = try? await client.cancel(taskId: taskId) { upsert(snapshot, on: deviceId); rebuild() }
    }

    func respondToApproval(taskId: String, approve: Bool) async throws { try await respondToApproval(taskId: taskId, approve: approve, forRestOfTask: false) }

    /// `forRestOfTask`: also cover the same kind of action for the remainder of this task (never offered for sensitive actions).
    func respondToApproval(taskId: String, approve: Bool, forRestOfTask: Bool) async throws {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { throw RemoteUnavailable() }
        guard let pending = transcripts[taskId]?.pendingApproval?.id ?? pendingByTask[taskId]?.id else { return }
        try await client.resolveApproval(id: pending, approve: approve, scope: forRestOfTask ? "task" : "once")
        pendingByTask[taskId] = nil
        if watchers[taskId] == nil { watch(taskId, on: deviceId) }
        await refresh(only: deviceId)
    }

    /// Loads (or reloads) a task's full log from the computer and keeps following it until it ends. Use when opening a task from an earlier launch.
    func openTask(_ taskId: String) async {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { return }
        if transcripts[taskId] == nil, let polled = try? await client.pollEvents(taskId: taskId, after: 0) {
            var t = RemoteTranscript(); for e in polled.events { t.apply(e) }
            transcripts[taskId] = t; upsert(polled.task, on: deviceId)
            if polled.task.lastSeq > t.lastSeq { transcripts[taskId] = nil }   // log is longer than one page: let the stream fill it in
        }
        if transcripts[taskId]?.isFinished != true { watch(taskId, on: deviceId) }
        rebuild()
    }

    /// Rebuilds a transcript from the computer's full durable log without touching the live one (what a fresh launch would show).
    func replayTranscript(_ taskId: String) async -> RemoteTranscript? {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { return nil }
        var t = RemoteTranscript(), after = 0
        while let page = try? await client.pollEvents(taskId: taskId, after: after) {
            for e in page.events { t.apply(e) }
            after = t.lastSeq
            if page.events.isEmpty || after >= page.task.lastSeq { return t }
        }
        return nil
    }

    /// Removes a finished task and its log from the computer.
    func deleteTask(_ taskId: String) async {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { return }
        if (try? await client.deleteTask(taskId)) != nil {
            computers[deviceId]?.tasks.removeAll { $0.id == taskId }; transcripts[taskId] = nil; pendingByTask[taskId] = nil
            save(); rebuild()
        }
    }

    /// Folders on the computer the phone may choose as a working folder (inside the roots its owner allowed).
    func folders(deviceId: String, path: String) async throws -> RemoteFolders {
        guard let client = clients[deviceId] else { throw RemoteUnavailable() }
        return try await client.folders(path: path)
    }

    // MARK: Model access and discovery

    /// Gives the computer model access: asks the gateway for a credential that is good for this account's model tasks only, hands it to the computer
    /// over the pinned, signed channel, and shows the computer's own check of it. Safe to repeat (the computer keeps one credential per Mac).
    func provisionAccess(deviceId: String) async {
        guard let client = clients[deviceId] ?? makeClient(deviceId) else { return }
        guard let account else { access[deviceId] = .problem(code: "account_unavailable", message: "账号服务暂时不可用。"); return }
        access[deviceId] = .providing; provisionAttempts[deviceId, default: 0] += 1
        do {
            let name = computers[deviceId]?.alias ?? computers[deviceId]?.record.name ?? "Mac"
            let credential = try await account.createComputerAccess(name: name)
            let state = try await client.provisionCloud(gateway: credential.gateway, token: credential.token, expiresAt: credential.expiresAt.map { $0.timeIntervalSince1970 * 1000 },
                                                        accountHint: credential.accountHint, sessionName: credential.name)
            apply(verification: state.verification, to: deviceId)
            statuses[deviceId] = (try? await client.status()) ?? statuses[deviceId]
            if let status = statuses[deviceId] { computers[deviceId]?.status = status }
            save(); rebuild()
        } catch let error as CloudServiceError {
            access[deviceId] = .problem(code: "signed_out", message: error.message)
        } catch let error as CloudAPIError {
            access[deviceId] = .problem(code: error.code, message: error.isNetwork ? "手机连不上 iTalk 云端。" : (error.errorDescription ?? error.code))
        } catch let error as RemoteError {
            access[deviceId] = .problem(code: "computer", message: error.errorDescription ?? "连接失败")
        } catch { access[deviceId] = .problem(code: "unknown", message: error.localizedDescription) }
        rebuild()
    }

    /// The computer asks the gateway itself (credential accepted? subscription active? which models?) and the phone shows the answer.
    func verifyAccess(deviceId: String) async {
        guard let client = clients[deviceId] ?? makeClient(deviceId) else { return }
        do { apply(verification: try await client.verifyCloud().verification, to: deviceId) }
        catch let error as RemoteError { access[deviceId] = .problem(code: "computer", message: error.errorDescription ?? "连接失败") }
        catch { access[deviceId] = .problem(code: "unknown", message: error.localizedDescription) }
        rebuild()
    }

    func loadCapabilities(deviceId: String, folder: String? = nil) async {
        guard let client = clients[deviceId] ?? makeClient(deviceId) else { return }
        if let caps = try? await client.capabilities(cwd: folder) { capabilities[deviceId] = caps }
    }

    /// Answers a question the agent asked in a running task.
    func answerQuestion(taskId: String, text: String) async throws {
        guard let deviceId = deviceId(forTask: taskId), let client = clients[deviceId] else { throw RemoteUnavailable() }
        guard let question = transcripts[taskId]?.pendingQuestion else { return }
        try await client.answer(questionId: question.id, text: text)
    }

    private func apply(verification: CloudVerification?, to id: String) {
        guard let v = verification else { return }
        if v.ok { access[id] = .ready(models: v.models ?? [], plan: v.subscription?.planName ?? v.subscription?.status) }
        else { access[id] = .problem(code: v.code ?? "unknown", message: Self.accessText(v.code, fallback: v.message)) }
    }

    /// What the status says about model access, unless the phone is in the middle of providing it.
    private func deriveAccess(_ id: String, from status: AgentStatus) {
        guard access[id] != .providing else { return }
        guard let b = status.backends.first(where: { $0.id == "italk" }) else {
            access[id] = .problem(code: "agent_outdated", message: "这台电脑上的 iTalk 智能体版本过旧，请在电脑上重新运行安装命令。"); return
        }
        if b.available { access[id] = .ready(models: b.modelInfo ?? [], plan: b.subscription?.planName ?? b.subscription?.status); return }
        switch b.detail {
        case "cloud_not_configured", nil: access[id] = .notConfigured
        default: access[id] = .problem(code: b.detail ?? "unknown", message: Self.accessText(b.detail, fallback: nil))
        }
        // Setting a freshly paired computer up needs no tapping: when the person is signed in, the phone does it once.
        if access[id] == .notConfigured, (provisionAttempts[id] ?? 0) == 0, account?.isSignedIn == true { Task { await provisionAccess(deviceId: id) } }
    }

    nonisolated static func accessText(_ code: String?, fallback: String?) -> String {
        switch code {
        case "cloud_not_configured": "这台电脑还没有模型访问权限。"
        case "cloud_auth": "云端不再接受这台电脑的凭证，请重新设置。"
        case "subscription_required": "需要有效的 iTalk 订阅，这台电脑才能使用 iTalk 模型。"
        case "model_not_in_plan": "当前订阅里没有这台电脑能用的模型。"
        case "cloud_unreachable": "这台电脑连不上 iTalk 云端，请检查它的网络。"
        case "cloud_error": "iTalk 云端暂时出了问题，请稍后再试。"
        default: fallback ?? "模型访问暂不可用（\(code ?? "未知")）。"
        }
    }

    // MARK: Refresh

    private func refresh(only deviceId: String?) async {
        guard !refreshing || deviceId != nil else { return }
        if deviceId == nil { refreshing = true }
        defer { if deviceId == nil { refreshing = false } }
        let ids = deviceId.map { [$0] } ?? Array(computers.keys)
        let jobs = ids.map { id in Task { await self.refreshOne(id) } }       // each suspends on the network, so computers refresh side by side
        for job in jobs { await job.value }
        rebuild()
    }

    /// `quiet`: a retry of a computer already known to be away keeps saying so instead of flashing "connecting" every few seconds.
    private func refreshOne(_ id: String, quiet: Bool = false) async {
        guard inFlight.insert(id).inserted else { return }
        defer { inFlight.remove(id) }
        guard let client = clients[id] ?? makeClient(id) else { return }
        if !quiet, connection[id] == nil || connection[id]?.isOnline == false { connection[id] = .connecting; rebuild() }
        do {
            _ = try await client.hello()
            connection[id] = .authenticating
            let status = try await client.status()
            statuses[id] = status; computers[id]?.status = status
            if status.agent.name != computers[id]?.record.name { computers[id]?.record.name = status.agent.name }
            deriveAccess(id, from: status)
            let snapshots = try await client.tasks()
            computers[id]?.tasks = snapshots
            computers[id]?.lastSeen = Date()
            connection[id] = .connected; unreachableSince[id] = nil
            if let approvals = try? await client.approvals() {
                pendingByTask = pendingByTask.filter { key, _ in !(snapshots.contains { $0.id == key }) }
                for a in approvals { pendingByTask[a.taskId] = RemoteApprovalRequest(id: a.id, summary: a.summary, risk: ToolRisk(rawValue: a.risk) ?? .modify, expiresAt: Date(timeIntervalSince1970: a.expiresAt / 1000)) }
            }
            for s in snapshots where !s.isFinished { watch(s.id, on: id) }
            // Finished tasks whose final events this phone has not seen yet (the phone was away when they ended).
            for s in snapshots.prefix(10) where s.isFinished && (transcripts[s.id]?.lastSeq ?? 0) < s.lastSeq && transcripts[s.id] != nil { watch(s.id, on: id) }
            save()
        } catch RemoteError.revoked {
            connection[id] = .revoked
        } catch RemoteError.identityMismatch {
            connection[id] = .failed("证书与配对时不一致")
        } catch let error as RemoteError {
            if error == .unreachable { markUnreachable(id) } else { connection[id] = .failed(error.errorDescription ?? "连接失败") }
        } catch { markUnreachable(id) }
    }

    private func markUnreachable(_ id: String) {
        let since = unreachableSince[id] ?? Date()
        unreachableSince[id] = since; connection[id] = .unreachable(since: since); rebuild()
    }

    private func suspendWatching() {
        // iOS suspends sockets in the background; the tasks themselves keep running on the computer.
        for (_, task) in watchers { task.cancel() }
        watchers.removeAll()
    }

    // MARK: Following a task

    private func watch(_ taskId: String, on deviceId: String) {
        guard watchers[taskId] == nil, let client = clients[deviceId] else { return }
        watchers[taskId] = Task { [weak self] in
            guard let center = self else { return }
            var transcript = center.transcripts[taskId] ?? RemoteTranscript()
            let feed = RemoteCompanionFeed(taskId: taskId)      // the character's view of this task (CompanionSignalHub)
            let stream = client.events(taskId: taskId, after: transcript.lastSeq) { status in
                Task { @MainActor in
                    switch status {
                    case .connected: center.connection[deviceId] = .connected
                    case .reconnecting(let n): center.connection[deviceId] = .reconnecting(attempt: n)
                    }
                    center.rebuild()
                    feed.connection(status)
                }
            }
            do {
                for try await event in stream {
                    transcript.apply(event)
                    feed.event(event)
                    center.transcripts[taskId] = transcript
                    if event.type == "approval_requested" || event.isTerminal || event.type == "tool_call" || event.type == "started" { center.rebuild() }
                }
            } catch RemoteError.revoked { center.connection[deviceId] = .revoked }
            catch { }
            center.watchers[taskId] = nil
            if !Task.isCancelled { await center.refresh(only: deviceId) } else { center.rebuild() }
        }
    }

    // MARK: Building the UI model

    private func rebuild() {
        devices = computers.values.sorted { $0.record.pairedAt < $1.record.pairedAt }.map { c in
            let id = c.record.id
            let state = connection[id] ?? .disconnected
            let lost = !state.isOnline && !{ if case .reconnecting = state { return true } else { return false } }()
            let tasks = c.tasks.map { taskInfo($0, deviceId: id, lost: lost) }.sorted { $0.updatedAt > $1.updatedAt }
            let platform = (statuses[id] ?? c.status)?.agent.platform.lowercased()
            let os: RemoteOS = switch platform { case "macos", "darwin": .mac; case "windows", "win32": .windows; case "linux": .linux; default: .other }
            return RemoteDeviceInfo(id: id, name: c.alias ?? c.record.name, os: os, state: state, pairedAt: c.record.pairedAt, lastSeen: c.lastSeen, fingerprint: c.record.fingerprint,
                                    models: Self.models(from: statuses[id] ?? c.status), tasks: tasks, skillIds: [], agentVersion: (statuses[id] ?? c.status)?.agent.version)
        }
    }

    private func taskInfo(_ s: RemoteTaskSnapshot, deviceId: String, lost: Bool) -> RemoteTaskInfo {
        var state: RemoteTaskState = switch s.state {
        case "queued": .queued
        case "running": s.pendingApprovals > 0 ? .awaitingApproval : .running
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: .lost
        }
        // The live event log is newer than the last task snapshot: let it decide while the phone is following the task.
        let transcript = transcripts[s.id]
        if let t = transcript, t.lastSeq > 0 {
            switch t.phase {
            case .completed: state = .completed
            case .failed: state = .failed
            case .cancelled: state = .cancelled
            case .running: state = t.pendingApproval != nil ? .awaitingApproval : .running
            }
        }
        if lost, !state.isFinished { state = .lost }
        var summary = ""
        if state == .failed { if case .failed(let code, let message)? = transcript?.phase { summary = message ?? Self.failureText(code) } else { summary = s.error?.message ?? Self.failureText(s.error?.code) } }
        else if let answer = transcript?.answer, !answer.isEmpty { summary = String(answer.suffix(140)).trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let last = transcript?.items.reversed().compactMap({ item -> String? in if case .step(let id) = item { return transcript?.steps[id]?.summary } else if case .note(let n) = item { return n } else { return nil } }).first { summary = last }
        let approval: RemoteApprovalRequest? = transcript?.pendingApproval.map { RemoteApprovalRequest(id: $0.id, summary: $0.summary, risk: $0.risk, expiresAt: $0.expiresAt) } ?? pendingByTask[s.id]
        return RemoteTaskInfo(id: s.id, deviceId: deviceId, title: s.title ?? "任务", modelId: s.model.map { "\(s.backend)/\($0)" } ?? s.backend, state: state, progress: nil, summary: summary,
                              startedAt: Date(timeIntervalSince1970: (s.startedAt ?? s.createdAt) / 1000), updatedAt: Date(timeIntervalSince1970: (s.finishedAt ?? s.startedAt ?? s.createdAt) / 1000),
                              lastSequence: s.lastSeq, pendingApproval: state == .awaitingApproval || approval != nil && !state.isFinished ? approval : nil)
    }

    private func upsert(_ snapshot: RemoteTaskSnapshot, on deviceId: String) {
        guard var c = computers[deviceId] else { return }
        if let i = c.tasks.firstIndex(where: { $0.id == snapshot.id }) { c.tasks[i] = snapshot } else { c.tasks.insert(snapshot, at: 0) }
        computers[deviceId] = c
    }

    private func deviceId(forTask taskId: String) -> String? { computers.first { $0.value.tasks.contains { $0.id == taskId } }?.key }

    nonisolated static func failureText(_ code: String?) -> String {
        switch code {
        case "interrupted": "电脑上的助手重启了，这个任务被中断。"
        case "cloud_not_configured": "这台电脑还没有模型访问权限，请在“我的电脑”里重新设置。"
        case "cloud_auth": "云端不再接受这台电脑的凭证，请在“我的电脑”里重新设置。"
        case "subscription_required": "需要有效的 iTalk 订阅。"
        case "quota_exceeded": "本周或本订阅周期的用量已用完。"
        case "model_not_in_plan": "当前订阅不包含这个模型。"
        case "concurrency_limited", "rate_limited": "iTalk 云端正忙，请稍后再试。"
        case "cloud_unreachable": "电脑连不上 iTalk 云端。"
        case "cloud_error", "cloud_stream_interrupted": "iTalk 云端暂时不可用，请稍后再试。"
        case "bad_request": "云端拒绝了这次请求。"
        case "local_unavailable": "电脑上的本地模型服务不可用，请确认 Ollama 正在运行。"
        case "local_model_unavailable", "local_no_supported_models": "电脑上没有可用的本地模型，请检查 Ollama 模型。"
        case "local_model_error", "local_stream_interrupted": "电脑上的本地模型未能完成回复，请重试。"
        case "backend_error", nil: "任务失败。"
        default: "任务失败（\(code ?? "")）。"
        }
    }

    /// Only list the models the connected computer reports as available.
    nonisolated static func models(from status: AgentStatus?) -> [RemoteModelInfo] {
        (status?.backends ?? []).filter { ["italk", "ollama"].contains($0.id) && $0.available }.flatMap { backend in
            (backend.modelInfo ?? backend.models.map { CloudModel(id: $0) }).map {
                RemoteModelInfo(id: "\(backend.id)/\($0.id)", name: (backend.id == "ollama" ? "电脑本地 · " : "iTalk · ") + ($0.name ?? $0.id), runtime: backend.id == "ollama" ? .local : .italk, isAgent: true, contextWindow: $0.contextTokens, supportsImages: $0.supportsImages ?? false,
                                supportsTools: $0.supportsTools ?? false, supportsReasoning: $0.supportsReasoning ?? false)
            }
        }
    }

    nonisolated static func resolve(_ modelId: String?, in status: AgentStatus) -> (backend: String?, model: String?) {
        guard let modelId else {
            guard let backend = status.backends.first(where: { $0.id == "italk" && $0.available }) ?? status.backends.first(where: { $0.id == "ollama" && $0.available }) else { return (nil, nil) }
            return (backend.id, nil)
        }
        guard let separator = modelId.firstIndex(of: "/") else { return (nil, nil) }
        let backend = String(modelId[..<separator]), model = String(modelId[modelId.index(after: separator)...])
        guard ["italk", "ollama"].contains(backend), !model.isEmpty,
              status.backends.contains(where: { $0.id == backend && $0.available && $0.models.contains(model) }) else { return (nil, nil) }
        return (backend, model)
    }

    // MARK: Storage

    private struct StoredComputer: Codable {
        var record: AgentRecord
        var alias: String?
        var lastSeen: Date?
        var tasks: [RemoteTaskSnapshot]
        var status: AgentStatus?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([StoredComputer].self, from: data) else { return }
        for c in list {
            computers[c.record.id] = c
            statuses[c.record.id] = c.status
            connection[c.record.id] = .disconnected
        }
    }

    private func save() {
        let list = Array(computers.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func identity() -> PhoneIdentity? { try? PhoneIdentity.loadOrCreate(in: secrets) }
    private func makeClient(_ id: String) -> RemoteAgentClient? {
        guard let record = computers[id]?.record, let identity = identity() else { return nil }
        let client = RemoteAgentClient(record: record, identity: identity)
        clients[id] = client
        return client
    }
    private static func phoneName() -> String { let n = UIDevice.current.name; return n.isEmpty ? "iPhone" : String(n.prefix(40)) }
}

/// The phone's signing key lives in the Keychain, readable after first unlock (so a refresh can sign while the phone is locked) and never synced.
struct KeychainRemoteSecrets: RemoteSecretStore {
    func load(_ account: String) -> Data? { KeychainStore.read(account) }
    func save(_ data: Data, account: String) throws { try KeychainStore.write(data, account: account, afterFirstUnlock: true) }
    func delete(_ account: String) { KeychainStore.delete(account) }
}

struct RemoteUnavailable: LocalizedError {
    var errorDescription: String? { "这台电脑当前不可用。" }
}
