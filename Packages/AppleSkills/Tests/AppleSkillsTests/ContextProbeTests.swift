import Foundation
import Testing
@testable import AppleSkills
@testable import AgentRuntime

// CONTEXT MEMORY
// Updated: 2026-10-31
// Status: verified (Mac)
// Why: A one-line request ("渲染几个选择题出来我看看你的skills") failed on the iPhone with "content too long for the context window". This probe runs the REAL runner
//      over the REAL skill catalog with a recording provider and writes every model request (messages, tool schemas, output reservation) as JSON, so the
//      real Qwen tokenizer and chat template (tools/context-probe/count_tokens.py) can count each section. Numbers only; it never needs a model.
// Debug Goal: Find which part of the prompt overflows a 4096-token on-device window, and show that a fix keeps every step inside it.
// Search Tags: context window budget tokens system prompt skill instructions overflow probe qwen
// Invariants:
// - The catalog, runner configuration and memory block are the ones the app builds (AgentPlatform.configure).
// - Nothing here contacts a model or the network.
// Failure Modes:
// - The app adds a skill that this test does not know about, so the probe under-counts. Keep `appCatalog` in step with AgentPlatform.

/// A provider that answers instantly with a script and keeps every request it was given.
final class RecordingProvider: ModelProvider, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let lock = NSLock()
    private var _requests: [GenerationRequest] = []
    private let selection: String
    private let answer: String
    private let toolCallOnFirstStep: ToolCall?
    /// Stands in for the model's tokenizer: the calibrated estimate divided by its median over-estimate on real text (1.25).
    var exactCounter: (@Sendable (GenerationRequest) -> Int)? = { r in
        let t = r.messages.reduce(0) { $0 + TokenEstimator.tokens($1) } + (r.tools.isEmpty ? 0 : r.tools.reduce(150) { $0 + TokenEstimator.tokens($1.schemaText) * 2 + 30 })
        return Int(Double(t) / 1.25)
    }
    var requests: [GenerationRequest] { lock.withLock { _requests } }
    func promptTokenCount(_ request: GenerationRequest) async -> Int? { exactCounter?(request) }

    init(window: Int, selection: String, answer: String = "好的。", toolCallOnFirstStep: ToolCall? = nil) {
        descriptor = ModelDescriptor(id: "qwen3.5-2b-4bit", kind: .localDownloaded, displayName: "Qwen3.5 2B",
                                     capabilities: ProviderCapabilities(contextWindow: window, toolCalling: .constrained, structuredOutput: false, maxAutonomy: .restrictedTools,
                                                                        worksOffline: true, sendsContentOffDevice: false, estimatedResidentBytes: 1_800_000_000, visionInput: true, skillSelection: .guided))
        self.selection = selection; self.answer = answer; self.toolCallOnFirstStep = toolCallOnFirstStep
    }
    func prepare(progress: @Sendable (PreparationState) -> Void) async throws { progress(.ready) }
    func unload() async {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let n = lock.withLock { () -> Int in _requests.append(request); return _requests.count }
        let isSelection = request.tools.isEmpty && request.maxTokens == 24
        return AsyncThrowingStream { c in
            if isSelection { c.yield(.textDelta(selection)); c.yield(.completed(.stop)) }
            else if let call = toolCallOnFirstStep, !request.messages.contains(where: { $0.role == .tool }), n >= 1 {
                c.yield(.toolCall(call)); c.yield(.completed(.toolCalls))
            } else { c.yield(.textDelta(answer)); c.yield(.usage(Usage(promptTokens: 0, completionTokens: 8, firstTokenLatency: 0.1, tokensPerSecond: 20, providerId: "probe"))); c.yield(.completed(.stop)) }
            c.finish()
        }
    }
}

struct StubMemory: MemoryContextSource {
    let items: [MemoryItem]
    func memoryContext(for text: String, characterBudget: Int, includeSensitive: Bool) async -> [MemoryItem] {
        var used = 0, out: [MemoryItem] = []
        for i in items { if used + i.text.count > characterBudget { break }; used += i.text.count; out.append(i) }
        return out
    }
}

/// The skill the UI session added (apps/iOS/GenerativeUISkill.swift), read from the app source so the probe sees the shipped text.
func generativeUISkillFromAppSource() throws -> Skill {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("apps/iOS/GenerativeUISkill.swift").path) { url.deleteLastPathComponent() }
    let source = try String(contentsOf: url.appendingPathComponent("apps/iOS/GenerativeUISkill.swift"), encoding: .utf8)
    let lines = source.components(separatedBy: "\n")
    guard let open = lines.firstIndex(where: { $0.contains("static let instructions = #\"\"\"") }),
          let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"\"\"#" }) else { throw ProbeError.notFound }
    let indent = lines[close].prefix { $0 == " " }.count
    let body = lines[(open + 1)..<close].map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    guard let s = lines.first(where: { $0.contains("summary: \"") }), let a = s.range(of: "summary: \""), let b = s.range(of: "\"", range: a.upperBound..<s.endIndex) else { throw ProbeError.notFound }
    func rawBlock(named name: String) -> String? {
        guard let open = lines.firstIndex(where: { $0.contains("static let \(name) = #\"\"\"") }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"\"\"#" }) else { return nil }
        let indent = lines[close].prefix { $0 == " " }.count
        return lines[(open + 1)..<close].map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }
    return Skill(id: "generative_ui", name: "交互界面", summary: String(s[a.upperBound..<b.lowerBound]), instructions: rawBlock(named: "instructions") ?? body, toolNames: [], brief: rawBlock(named: "brief"))
}
enum ProbeError: Error { case notFound }

/// The catalog and tools the app builds in AgentPlatform.configure (Apple skills, web, memory, generative UI).
func appCatalog(includeGenerativeUI: Bool = true) throws -> (ToolRegistry, SkillCatalog) {
    var (reg, cat, _) = installed()
    var all = SkillCatalog([SkillCatalog.standard.skill("core")!])
    all.add(cat.skills)
    reg.register(DateTimeTool()); reg.register(CalculatorTool())
    let web = WebSession()
    for t in WebSkill.tools(chain: .standard(mainland: true), session: web) { reg.register(t) }
    all.add(WebSkill.skill)
    // Mirrors `MemoryTools.skill` (apps/iOS/AgentPlatform.swift): only the id, name and one-line summary reach the always-present catalog.
    all.add(Skill(id: "memory", name: "长期记忆", summary: "保存与查找用户批准的长期记忆",
                  instructions: "只有用户明确要求“记住”时才用 memory_save（会请用户确认）；用户要求修改或忘记某件事时，先 memory_search 找到 id，再用 memory_update / memory_forget。",
                  toolNames: ["memory_save", "memory_search", "memory_update", "memory_forget"]))
    if includeGenerativeUI { all.add(try generativeUISkillFromAppSource()) }
    return (reg, all)
}

private func mlxSchema(_ spec: ToolSpec) -> [String: Any] {
    var props: [String: Any] = [:]
    for (k, p) in spec.parameters {
        var d: [String: Any] = ["type": p.kind.rawValue, "description": p.description]
        if let e = p.enumValues { d["enum"] = e }
        props[k] = d
    }
    let required: [String] = spec.parameters.filter(\.value.required).keys.sorted()
    return ["type": "function", "function": ["name": spec.name, "description": spec.description,
                                             "parameters": ["type": "object", "properties": props, "required": required] as [String: Any]] as [String: Any]]
}

func dump(_ requests: [GenerationRequest], window: Int, name: String, extra: [String: Any] = [:]) throws {
    guard let dir = ProcessInfo.processInfo.environment["ITALK_CONTEXT_DUMP"] else { return }
    let reqs: [[String: Any]] = requests.enumerated().map { i, r in
        let isSelection = r.tools.isEmpty && r.maxTokens == 24
        return ["index": i, "kind": isSelection ? "selection" : "step", "maxTokens": r.maxTokens, "reasoning": r.reasoning,
                "messages": r.messages.map { m -> [String: Any] in
                    var d: [String: Any] = ["role": m.role.rawValue, "content": m.text]
                    if !m.toolCalls.isEmpty { d["tool_calls"] = m.toolCalls.map { ["function": ["name": $0.name, "arguments": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0.arguments))) ?? [:]]] } }
                    if let id = m.toolCallId { d["tool_call_id"] = id }
                    return d },
                "tools": r.tools.map(mlxSchema)]
    }
    var doc: [String: Any] = ["scenario": name, "window": window, "requests": reqs]
    for (k, v) in extra { doc[k] = v }
    try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
}

/// Runs one turn through the real runner and returns what the provider was sent plus the final run state.
func runTurn(provider: RecordingProvider, text: String, history: [ModelMessage] = [], reasoning: Bool = false, memory: [MemoryItem] = [], includeGenerativeUI: Bool = true) async throws -> (RunSnapshot, [GenerationRequest]) {
    let (reg, cat) = try appCatalog(includeGenerativeUI: includeGenerativeUI)
    let runner = AgentRunner(provider: provider, tools: reg, skills: cat, store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
    await runner.setReasoning(reasoning)
    if !memory.isEmpty { await runner.setMemory(StubMemory(items: memory)) }
    let id = try await runner.start(conversationId: UUID(), text: text, history: history)
    await runner.waitUntilIdle(id)
    return (await runner.snapshot(id)!, provider.requests)
}

func reportsJSON(_ run: RunSnapshot) -> Any {
    guard let data = try? JSONEncoder().encode(run.contextReports ?? []), let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
    return obj
}

private let owner = "渲染几个选择题出来我看看你的skills"

@Test func probeOwnersRequestOnA4kWindowWithGenerativeUISelected() async throws {
    let provider = RecordingProvider(window: 4096, selection: "generative_ui", answer: "好的，这是几道选择题。")
    let (run, requests) = try await runTurn(provider: provider, text: owner)
    try dump(requests, window: 4096, name: "owner-request-selects-generative-ui", extra: ["finalState": run.state.rawValue, "failure": run.failure ?? "", "reports": reportsJSON(run)])
    print("PROBE owner request: state=\(run.state.rawValue) failure=\(run.failure ?? "-") requests=\(requests.count) loadedSkills=\(run.loadedSkills)")
}

@Test func probeOwnersRequestWithThinkingOn() async throws {
    let provider = RecordingProvider(window: 4096, selection: "generative_ui", answer: "好的，这是几道选择题。")
    let (run, requests) = try await runTurn(provider: provider, text: owner, reasoning: true)
    try dump(requests, window: 4096, name: "owner-request-thinking-on", extra: ["finalState": run.state.rawValue, "failure": run.failure ?? "", "reports": reportsJSON(run)])
    print("PROBE owner request, thinking on: state=\(run.state.rawValue) failure=\(run.failure ?? "-") requests=\(requests.count)")
}

@Test func probePlainChatOnA4kWindow() async throws {
    let provider = RecordingProvider(window: 4096, selection: "none", answer: "你好！")
    let (run, requests) = try await runTurn(provider: provider, text: "你好，介绍一下你自己")
    try dump(requests, window: 4096, name: "plain-chat", extra: ["finalState": run.state.rawValue, "failure": run.failure ?? "", "reports": reportsJSON(run)])
    print("PROBE plain chat: state=\(run.state.rawValue) failure=\(run.failure ?? "-") requests=\(requests.count)")
}
