import Foundation
import Testing
#if os(iOS)
import os
#endif
import AgentRuntime
import MLX
import MLXProvider

/// Real-model integration + benchmark. Runs only when ITALK_MODEL_DIR points at an installed MLX model directory.
/// Results are measurements from THIS machine; they say nothing about iPhone performance.
/// Output: JSON at ITALK_BENCH_OUT (default: stdout line prefixed BENCH:).
struct Bench: Codable {
    var model: String; var machine: String; var loadSeconds = 0.0
    var coldFirstTokenSeconds: Double?; var warmFirstTokenSeconds: [Double] = []; var warmTokensPerSecond: [Double] = []
    var chatFirstTokenSeconds: Double?; var chatTokensPerSecond: Double?; var chatCompletionTokens = 0; var chatText = ""
    var peakMemoryMB = 0.0; var activeMemoryMB = 0.0
    var calcTrials = 0; var calcProposedValid = 0; var calcFinalCorrect = 0
    var reminderTrials = 0; var reminderApprovalCardShown = 0; var reminderSideEffects = 0
    var cancelStopMillis: Double?; var cancelStaleDeltas = -1
    var thinkingLeakedIntoText = false
    var toolProbe: [String] = []; var diagnostics: [String] = []
    var downloadSeconds: Double?; var thermalStart = ""; var thermalEnd = ""; var processAvailableMB: Double?; var physicalMemoryMB = 0.0; var os = ""
}

final class NoRemind: ReminderStore, @unchecked Sendable {
    var calls = 0
    func create(title: String, due: Date?, idempotencyKey: String) async throws -> String { calls += 1; return "x" }
    func exists(idempotencyKey: String) async -> String? { nil }
    func verify(id: String) async -> Bool { true }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ITALK_MODEL_DIR"] != nil || ProcessInfo.processInfo.environment["ITALK_MODEL_ID"] != nil))
func realLocalModelThroughSharedRunner() async throws {
    let env = ProcessInfo.processInfo.environment
    var downloadSeconds: Double?
    let dir: URL
    if let id = env["ITALK_MODEL_ID"], let art = ModelCatalog.all.first(where: { $0.id == id }) {
        // On-device path: real download from the pinned catalog through ModelStore (hash verified), then load.
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("italk-bench")
        let store = try ModelStore(root: root)
        if !(await store.isInstalled(art)) {
            let t = ContinuousClock.now
            try await store.install(art, sources: SourcePlanner.order(art, policy: .current()))
            downloadSeconds = (ContinuousClock.now - t).secs
        }
        dir = await store.directory(for: art.id)!
    } else {
        dir = URL(fileURLWithPath: env["ITALK_MODEL_DIR"]!)
    }
    let trials = Int(ProcessInfo.processInfo.environment["ITALK_TRIALS"] ?? "5") ?? 5
    let artifact = ModelArtifact(id: dir.lastPathComponent, displayName: dir.lastPathComponent, version: "bench", license: "apache-2.0", baseModelLicense: "apache-2.0",
                                 files: [], residentBytes: 0, kvBytesPerToken: 0, contextTokens: 4096, maxAutonomy: .restrictedTools, autonomySource: "benchmark harness")
    let diag = DiagBox()
    let provider = MLXModelProvider(artifact: artifact, directory: dir, diagnostic: { diag.add($0) })
    var bench = Bench(model: dir.lastPathComponent, machine: ProcessInfo.processInfo.hostName)
    bench.downloadSeconds = downloadSeconds
    bench.thermalStart = "\(ProcessInfo.processInfo.thermalState.rawValue)"
    bench.physicalMemoryMB = Double(ProcessInfo.processInfo.physicalMemory) / 1e6
    bench.os = ProcessInfo.processInfo.operatingSystemVersionString
    #if os(iOS)
    bench.processAvailableMB = Double(os_proc_available_memory()) / 1e6
    #endif

    let t0 = ContinuousClock.now
    try await provider.prepare { _ in }
    bench.loadSeconds = (ContinuousClock.now - t0).secs

    // 1. Plain Chinese chat through the provider contract: first run is cold (GPU kernel warmup), the rest are warm.
    for i in 0..<4 {
        var text = "", usage: Usage?
        for try await e in provider.generate(GenerationRequest(messages: [.init(role: .system, text: "你是简洁的中文助手。"), .init(role: .user, text: "用一句话介绍一下你自己。")], maxTokens: 120)) {
            switch e { case .textDelta(let d): text += d; case .usage(let u): usage = u; default: break }
        }
        if i == 0 { bench.coldFirstTokenSeconds = usage?.firstTokenLatency; bench.chatText = text; bench.chatCompletionTokens = usage?.completionTokens ?? 0
            bench.thinkingLeakedIntoText = text.contains("<think>"); #expect(!text.isEmpty) }
        else { if let f = usage?.firstTokenLatency { bench.warmFirstTokenSeconds.append(f) }; if let t = usage?.tokensPerSecond { bench.warmTokensPerSecond.append(t) } }
    }
    // Probe: what does the model actually emit when offered the calculator?
    let calcSpec = CalculatorTool().spec
    for try await e in provider.generate(GenerationRequest(messages: [.init(role: .system, text: "需要计算时调用 calculate 工具。"), .init(role: .user, text: "请帮我算一下 12*(3+4) 等于多少")], tools: [calcSpec], maxTokens: 150)) {
        switch e { case .textDelta(let d): bench.toolProbe.append("text:" + d); case .toolCall(let c): bench.toolProbe.append("call:\(c.name) \(c.arguments.compactString)"); default: break }
    }

    // 2. Tool use through the real runner: model must propose calculate with valid args.
    let reminders = NoRemind()
    for _ in 0..<trials {
        let runner = AgentRunner(provider: provider, tools: ToolRegistry([DateTimeTool(), CalculatorTool(), CreateReminderTool(store: reminders)]),
                                 store: InMemoryRunStore(), granted: { Set(Capability.allCases) })
        let id = try await runner.start(conversationId: UUID(), text: "请帮我算一下 12*(3+4) 等于多少")
        await runner.waitUntilIdle(id)
        let s = await runner.snapshot(id)!
        bench.calcTrials += 1
        if s.toolCalls >= 1, s.messages.contains(where: { $0.role == .tool && $0.text.contains("84") }) { bench.calcProposedValid += 1 }
        if s.state == .completed, s.finalText?.contains("84") == true { bench.calcFinalCorrect += 1 }
    }
    // 3. Reminder must reach an approval card and never execute without approval.
    for _ in 0..<trials {
        let runner = AgentRunner(provider: provider, tools: ToolRegistry([DateTimeTool(), CalculatorTool(), CreateReminderTool(store: reminders)]),
                                 store: InMemoryRunStore(), granted: { Set(Capability.allCases) })
        let id = try await runner.start(conversationId: UUID(), text: "提醒我明天下午三点开会")
        await runner.waitUntilIdle(id)
        let s = await runner.snapshot(id)!
        bench.reminderTrials += 1
        if s.state == .awaitingApproval { bench.reminderApprovalCardShown += 1 }
    }
    bench.reminderSideEffects = reminders.calls

    // 4. Cancellation: time from the consumer cancelling until the engine has actually released the GPU, and count output after cancel.
    let counts = Counter()
    let consumer = Task {
        for try await e in provider.generate(GenerationRequest(messages: [.init(role: .user, text: "请写一篇关于上海的五百字文章。")], maxTokens: 400)) {
            if case .textDelta = e { counts.hit(afterCancel: Task.isCancelled) }
        }
    }
    while counts.seen < 5 { try await Task.sleep(for: .milliseconds(20)) }
    let cancelAt = ContinuousClock.now
    consumer.cancel()
    while await provider.activeGenerations > 0, (ContinuousClock.now - cancelAt).secs < 10 { try await Task.sleep(for: .milliseconds(5)) }
    bench.cancelStopMillis = (ContinuousClock.now - cancelAt).secs * 1000
    bench.cancelStaleDeltas = counts.stale
    _ = try? await consumer.value

    bench.peakMemoryMB = Double(Memory.peakMemory) / 1e6
    bench.activeMemoryMB = Double(Memory.activeMemory) / 1e6
    bench.diagnostics = diag.items
    bench.thermalEnd = "\(ProcessInfo.processInfo.thermalState.rawValue)"
    await provider.unload()
    let json = String(data: try JSONEncoder().encode(bench), encoding: .utf8)!
    if let out = ProcessInfo.processInfo.environment["ITALK_BENCH_OUT"] { try json.write(toFile: out, atomically: true, encoding: .utf8) }
    print("BENCH:", json)
}

final class DiagBox: @unchecked Sendable {
    private let lock = NSLock(); private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}

extension Duration { var secs: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 } }

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var s = 0, st = 0
    func hit(afterCancel: Bool) { lock.withLock { s += 1; if afterCancel { st += 1 } } }
    var seen: Int { lock.withLock { s } }
    var stale: Int { lock.withLock { st } }
}
