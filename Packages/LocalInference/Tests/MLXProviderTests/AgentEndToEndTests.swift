import Foundation
import Testing
import AgentRuntime
import AppleSkills
import MLXProvider

/// Real model → real runner → real skill catalog → tool execution, with Apple-framework tools stubbed on the Mac
/// (permissions and system UI need a phone) and web tools live. Prints the trace of every prompt.
/// ITALK_MODEL_DIR=<model folder> ITALK_PROMPTS="a|b|c" xcodebuild test …
final class Recorder: @unchecked Sendable {
    private let lock = NSLock(); private var _calls: [String] = []
    func add(_ s: String) { lock.withLock { _calls.append(s) } }
    func reset() { lock.withLock { _calls.removeAll() } }
    var calls: [String] { lock.withLock { _calls } }
}

struct StubbedTool: AgentTool {
    let inner: any AgentTool
    let rec: Recorder
    var spec: ToolSpec { inner.spec }
    func describe(_ a: JSONValue) -> String { inner.describe(a) }
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        rec.add("\(spec.name) \(arguments.compactString)")
        switch spec.name {
        case "alarm_set":
            let raw = arguments["time"]?.string ?? ""
            let clock = raw.wholeMatch(of: /(\d{1,2})[:：](\d{2})/)
            let validClock = clock.map { (Int($0.1) ?? 24) < 24 && (Int($0.2) ?? 60) < 60 } ?? false
            guard validClock || ((raw.contains("-") || raw.contains("/")) && ArgDate.parse(raw, now: context.now) != nil) else {
                throw ToolFailure("闹钟时间无效。倒计时请使用 timer_start 的 seconds。", retryable: false)
            }
            return ToolOutput(value: .object(["alarm": .object(["id": .string("A1"), "time": .string(raw)])]), summary: "已设置闹钟")
        case "alarm_cancel":
            guard let id = arguments["id"]?.string, UUID(uuidString: id) != nil else { throw ToolFailure("id 无效", retryable: false) }
            return ToolOutput(value: .object(["cancelled": .bool(true)]), summary: "已取消")
        case "timer_start": return ToolOutput(value: .object(["verified": .bool(true), "seconds": arguments["seconds"] ?? .null]), summary: "已开始计时")
        case "location_current": return ToolOutput(value: .object(["city": .string("测试城市")]), summary: "已获取位置")
        case "health_query": return ToolOutput(value: .object(["metric": .string("steps"), "value": .number(4321)]), summary: "已读取 steps")
        case "weather_forecast": return ToolOutput(value: .object(["place": .string("杭州"), "now": .object(["temperature": .number(18), "weather": .string("晴")])]), summary: "杭州：晴 18°C")
        default: return ToolOutput(value: .object(["stub": .bool(true)]), summary: "(stub) \(spec.name)")
        }
    }
}

#if targetEnvironment(simulator)
private let realModelTestAvailable = false // MLX Metal device initialization crashes this simulator runtime.
#else
private let realModelTestAvailable = true
#endif
@Test(.enabled(if: realModelTestAvailable && ProcessInfo.processInfo.environment["ITALK_MODEL_DIR"] != nil && ProcessInfo.processInfo.environment["ITALK_PROMPTS"] != nil))
func agentEndToEndWithRealModel() async throws {
    let env = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: env["ITALK_MODEL_DIR"]!)
    let artifact = ModelArtifact(id: dir.lastPathComponent, displayName: dir.lastPathComponent, version: "e2e", license: "apache-2.0", baseModelLicense: "apache-2.0",
                                 files: [], residentBytes: 0, kvBytesPerToken: 0, contextTokens: 4096, maxAutonomy: .fullAgent, autonomySource: "e2e")
    let provider = MLXModelProvider(artifact: artifact, directory: dir)
    try await provider.prepare { _ in }
    let rec = Recorder()
    var reg = ToolRegistry(), cat = SkillCatalog([])
    AppleSkills.install(into: &reg, catalog: &cat, context: AppleSkillContext(presenter: E2EUI(), filesRoot: FileManager.default.temporaryDirectory))
    var all = SkillCatalog([SkillCatalog.standard.skill("core")!]); all.add(WebSkill.skill); all.add(cat.skills)
    var wrapped = ToolRegistry([DateTimeTool(), CalculatorTool()])
    for n in reg.names { if let t = reg.tool(named: n) { wrapped.register(StubbedTool(inner: t, rec: rec)) } }
    let web = WebSession()
    for t in WebSkill.tools(chain: .standard(mainland: false), session: web) { wrapped.register(t) }
    var report: [[String: String]] = []
    for prompt in env["ITALK_PROMPTS"]!.split(separator: "|").map(String.init) {
        rec.reset()
        let runner = AgentRunner(provider: provider, tools: wrapped, skills: all, store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
        await runner.setReasoning(env["ITALK_THINK"] == "1")
        let t0 = ContinuousClock.now
        let id = try await runner.start(conversationId: UUID(), text: prompt, source: env["ITALK_VOICE"] != nil ? "voice" : "text")
        var approvals = 0
        while true {
            await runner.waitUntilIdle(id)
            let s = await runner.snapshot(id)!
            if s.state == .awaitingApproval, approvals < 3, let p = s.pending, let c = s.components[p.componentId]?.component {
                approvals += 1
                try await runner.submit(UIActionResponse(runId: id, componentId: c.id, componentRevision: c.revision, actionId: "approve", idempotencyKey: UUID().uuidString))
                continue
            }
            break
        }
        let s = await runner.snapshot(id)!
        let steps = s.messages.dropFirst(s.contextCount ?? 1)
        var trace: [String] = []
        for m in steps {
            if m.role == .assistant { trace.append("A[" + m.text.prefix(80).replacingOccurrences(of: "\n", with: " ") + "]" + m.toolCalls.map { " →\($0.name)(\(ActivityPreview.short($0.arguments)))" }.joined()) }
            if m.role == .tool { trace.append("T[" + m.text.prefix(100).replacingOccurrences(of: "\n", with: " ") + "]") }
        }
        let secs = (ContinuousClock.now - t0).components.seconds
        let thoughts = (s.reasoning ?? []).map { "REASONING[\($0.step)] " + $0.text.prefix(160).replacingOccurrences(of: "\n", with: " ") }
        print("E2E ─ \(prompt)\n    state=\(s.state) steps=\(s.modelSteps) tools=\(s.toolCalls) nudges=\(s.nudges ?? 0) \(secs)s\n    " + trace.joined(separator: "\n    ") + "\n    FINAL: \(s.finalText ?? "-")\n    STUBBED CALLS: \(rec.calls)\n    " + thoughts.joined(separator: "\n    "))
        if env["ITALK_ASSERT_TOOL_CALLS"] == "1" {
            let expected: String? = switch prompt {
            case "帮我设置15秒的倒计时": "timer_start"
            case "我现在在哪里": "location_current"
            case "杭州天气怎么样": "weather_forecast"
            default: nil
            }
            if let expected {
                #expect(s.state == .completed, "\(prompt): run must finish")
                #expect(rec.calls.contains { $0.hasPrefix(expected + " ") }, "\(prompt): expected \(expected), got \(rec.calls)")
                if expected == "timer_start" { #expect(rec.calls.contains { $0.contains("\"seconds\":15") }, "timer duration must be 15 seconds") }
                if expected == "location_current" {
                    let answer = s.finalText ?? ""
                    #expect(answer.range(of: #"[-+]?\d{1,3}\.\d+\s*[,，]\s*[-+]?\d{1,3}\.\d+"#, options: .regularExpression) == nil,
                            "the location fixture contains a city only; coordinates must not be invented")
                }
            }
        }
        report.append(["prompt": prompt, "state": s.state.rawValue, "tools": "\(s.toolCalls)", "final": s.finalText ?? "", "calls": rec.calls.joined(separator: " | ")])
    }
    if let out = env["ITALK_AGENT_OUT"] { try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: out)) }
    await provider.unload()
}

enum ActivityPreview { static func short(_ v: JSONValue) -> String { String(v.compactString.prefix(90)) } }

struct E2EUI: SystemPresenter {
    @MainActor func open(_ url: URL) async -> Bool { true }
    @MainActor func canOpen(_ url: URL) -> Bool { true }
    @MainActor func composeMessage(recipients: [String], body: String) async -> String { "sent" }
    @MainActor func composeMail(to: [String], subject: String, body: String) async -> String { "sent" }
    @MainActor func capturePhoto() async -> URL? { nil }
    @MainActor func pickDocument() async -> URL? { nil }
    @MainActor func share(_ file: URL) async -> Bool { true }
    @MainActor func setScreenBrightness(_ value: Double) -> Bool { true }
    @MainActor func screenBrightness() -> Double? { 0.5 }
}
