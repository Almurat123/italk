import Testing
import Foundation
@testable import AgentRuntime

// CONTEXT MEMORY
// Updated: 2026-10-31
// Status: verified (Mac)
// Why: A one-line request ("渲染几个选择题出来我看看你的skills") failed on the owner's iPhone with "context too large" four times: a skill's full instructions (1,547
//      real tokens) went into a 4,096-token window, thinking reserved 2,048 of it, and a character estimate decided. These tests pin the repaired behavior.
// Debug Goal: Every request fits its window by the model's own count; optional parts give way in a fixed order; nothing the person said is dropped silently.
// Search Tags: context budget skill brief thinking reservation history rebuild tool pairs report numbers only estimator
// Invariants:
// - A provider's exact count (here: the calibrated estimate without its 1.2 safety scale) decides; the estimate alone is only a fallback.
// - Reports contain numbers and short decision names, never conversation text.
// Failure Modes:
// - Testing with a window so large nothing is ever tight; every window below is chosen to force the step under test.

/// A scripted provider that "counts" prompts the way a tokenizer would (the calibrated estimate without its safety scale).
private final class CountingProvider: ModelProvider, @unchecked Sendable {
    let inner: ScriptedModelProvider
    let exact: Bool
    var descriptor: ModelDescriptor { inner.descriptor }
    var requests: [GenerationRequest] { inner.requests }
    init(window: Int, guided: Bool = true, exact: Bool = true, steps: [ScriptedModelProvider.Step]) {
        let caps = ProviderCapabilities(contextWindow: window, toolCalling: .constrained, structuredOutput: false, maxAutonomy: .fullAgent, worksOffline: true,
                                        sendsContentOffDevice: false, skillSelection: guided ? .guided : .native)
        inner = ScriptedModelProvider(descriptor: ModelDescriptor(id: "counting", kind: .localDownloaded, displayName: "counting", capabilities: caps), steps: steps)
        self.exact = exact
    }
    func prepare(progress: @Sendable (PreparationState) -> Void) async throws { progress(.ready) }
    func unload() async {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> { inner.generate(request) }
    func promptTokenCount(_ request: GenerationRequest) async -> Int? {
        guard exact else { return nil }
        let tools = request.tools.isEmpty ? 0 : request.tools.reduce(150) { $0 + TokenEstimator.tokens($1.schemaText) + 30 }
        return Int(Double(ContextFit.total(request.messages) + tools) / 1.2)
    }
}

private func selection(_ ids: String) -> ScriptedModelProvider.Step { .init([.textDelta(ids), .completed(.stop)]) }
private func plain() -> RunnerConfig { var c = RunnerConfig(); c.semanticCues = false; return c }
private func longSkill() -> Skill {
    Skill(id: "big", name: "大技能", summary: "很长的说明", instructions: String(repeating: "这是一条很长的使用说明。", count: 260), toolNames: [], brief: "【短说明】先判断再回答。")
}
private func run(_ provider: CountingProvider, text: String, history: [ModelMessage] = [], skills: [Skill] = [], tools: [any AgentTool] = [], thinking: Bool = false,
                 rebuild: AgentRunner.HistoryRebuilder? = nil) async throws -> RunSnapshot {
    var cat = SkillCatalog.standard; cat.add(skills)
    let runner = AgentRunner(provider: provider, tools: ToolRegistry(tools), skills: cat, store: InMemoryRunStore(), granted: { allCaps }, config: plain())
    await runner.setReasoning(thinking)
    let id = try await runner.start(conversationId: UUID(), context: history + [ModelMessage(role: .user, text: text)], historyRebuilder: rebuild)
    await runner.waitUntilIdle(id)
    return await runner.snapshot(id)!
}

@Test func aLongSkillGivesItsShortFormOnASmallWindowAndTheFullTextOnALargeOne() async throws {
    for (window, expectFull) in [(4096, false), (32768, true)] {
        let provider = CountingProvider(window: window, steps: [selection("big"), text("好的。")])
        let s = try await run(provider, text: "给我看看", skills: [longSkill()])
        let system = provider.requests.last!.messages.first!.text
        #expect(s.state == .completed, "window \(window): \(s.failure ?? "")")
        #expect(system.contains("【短说明】") == !expectFull && system.contains("这是一条很长的使用说明。") == expectFull, "window \(window)")
    }
}

@Test func theOwnersRequestShapeFitsA4kWindowWithThinkingOnAndKeepsThinking() async throws {
    // Guided selection picks a skill whose full instructions alone are about half the window; thinking is on (2,048 tokens wanted for output).
    let provider = CountingProvider(window: 4096, steps: [selection("big"), text("好的。")])
    let s = try await run(provider, text: "渲染几个选择题出来我看看你的skills", skills: [longSkill()], thinking: true)
    #expect(s.state == .completed && s.failure == nil, "\(s.failure ?? "") \(s.failureDetail ?? "")")
    let request = provider.requests.last!
    #expect(request.reasoning && request.maxTokens >= 768, "thinking stays on while the prompt leaves room: maxTokens \(request.maxTokens)")
    let report = s.contextReports!.last { $0.kind == "step" }!
    #expect(report.outcome == "ok" && report.exact && report.attempts.isEmpty && report.window == 4096 && report.promptTokens + report.reservedOutput <= 4096, "\(report)")
}

@Test func thinkingIsSwitchedOffForTheStepInsteadOfFailingWhenOnlyAPlainAnswerFits() async throws {
    // About 3,050 tokens of the person's own text: with thinking the answer room (768) does not fit, a plain answer (256) does.
    let long = String(repeating: "今天要整理的材料包括很多方面。", count: 380)
    let provider = CountingProvider(window: 4096, steps: [selection("none"), text("好的。")])
    let s = try await run(provider, text: long, thinking: true)
    #expect(s.state == .completed, "\(s.failure ?? "") \(s.failureDetail ?? "")")
    #expect(provider.requests.last!.reasoning == false)
    #expect(s.contextReports!.last { $0.kind == "step" }!.attempts == ["thinking_off"], "\(s.contextReports!.last!.attempts)")
}

@Test func theHistoryIsRebuiltSmallerThroughTheRebuilderBeforeAnythingIsDropped() async throws {
    let old = String(repeating: "较早的内容需要被总结。", count: 70)
    let history = [ModelMessage(role: .system, text: "【较早对话的摘要】用户喜欢简短回答。"), ModelMessage(role: .user, text: old), ModelMessage(role: .assistant, text: old), ModelMessage(role: .user, text: old),
                   ModelMessage(role: .assistant, text: old)]
    let target = Locked<Int>(0)
    let provider = CountingProvider(window: 1500, steps: [selection("none"), text("好的。")])
    let s = try await run(provider, text: "现在的问题", history: history, rebuild: { maxTokens in
        target.set(maxTokens)
        return [ModelMessage(role: .system, text: "【较早对话的摘要】用户喜欢简短回答。更早的内容已总结。"), ModelMessage(role: .user, text: "现在的问题")]
    })
    #expect(s.state == .completed, "\(s.failure ?? "") \(s.failureDetail ?? "")")
    let sent = provider.requests.last!.messages
    #expect(!sent.contains { $0.text.contains("较早的内容需要被总结") }, "the old turns were replaced by the rebuilt summary")
    #expect(sent.contains { $0.text.contains("更早的内容已总结") } && sent.last?.text == "现在的问题", "the summary and the current request are in the request")
    #expect(s.contextReports!.last { $0.kind == "step" }!.attempts.contains("history_compacted"))
    #expect(target.value >= 256 && target.value < 1500, "the rebuilder was given the room that was left: \(target.value)")
    #expect(s.contextCount == 2, "the stored run now holds the rebuilt history")
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}

private struct HugeReadTool: AgentTool {
    let spec = ToolSpec(name: "big_read", description: "读取一份很长的资料", permission: .readOnly, capability: .device)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(value: .object(["text": .string(String(repeating: "资料内容。", count: 4000))]), summary: "读到 20000 字")
    }
}

@Test func aHugeToolResultIsShortenedForTheNextStepAndThePairStaysIntact() async throws {
    let reader = Skill(id: "bigread", name: "资料", summary: "读取资料", instructions: "", toolNames: ["big_read"])
    let provider = CountingProvider(window: 3000, steps: [selection("bigread"),
        .init([.toolCall(ToolCall(id: "b1", name: "big_read", arguments: .object([:]))), .completed(.toolCalls)]), text("总结完成。")])
    let s = try await run(provider, text: "读一下并总结", skills: [reader], tools: [HugeReadTool()])
    #expect(s.state == .completed && s.finalText == "总结完成。", "\(s.state) \(s.failure ?? "") \(s.failureDetail ?? "")")
    let last = provider.requests.last!.messages
    let call = last.firstIndex { $0.role == .assistant && $0.toolCalls.contains { $0.id == "b1" } }
    let result = last.firstIndex { $0.role == .tool && $0.toolCallId == "b1" }
    #expect(call != nil && result != nil && call! < result!, "the call and its result travel together")
    #expect(last[result!].text.contains("已省略"), "the result was shortened, not dropped")
    #expect(s.contextReports!.last { $0.kind == "step" }!.attempts.contains { $0.hasPrefix("tool_results_shortened") })
}

@Test func whenNothingCanGiveTheRunFailsWithNumbersAndNoConversationText() async throws {
    let secret = "我的秘密口令是红色的鲸鱼"
    let provider = CountingProvider(window: 300, steps: [selection("none"), text("不应该被调用")])
    let s = try await run(provider, text: secret)
    #expect(s.state == .failed && s.failure == "context_too_large")
    #expect(s.failureDetail?.contains("window 300") == true, "\(s.failureDetail ?? "-")")
    let encoded = String(decoding: try JSONEncoder().encode(s.contextReports ?? []), as: UTF8.self) + (s.failureDetail ?? "")
    #expect(!encoded.contains("秘密") && !encoded.contains("鲸鱼"), "reports carry numbers only")
    #expect(s.contextReports?.last?.outcome == "too_large")
}

@Test func theSelectionRequestIsReportedWithItsOwnSize() async throws {
    let provider = CountingProvider(window: 4096, steps: [.init([.textDelta("none"), .usage(Usage(promptTokens: 666, completionTokens: 1, providerId: "t")), .completed(.stop)]), text("你好。")])
    let s = try await run(provider, text: "你好")
    let r = s.contextReports!.first { $0.kind == "selection" }
    #expect(r?.promptTokens == 666 && r?.exact == true && r?.step == 0, "\(String(describing: r))")
}

@Test func readingALongSkillGivesTheShortFormOnASmallWindowOnly() async throws {
    for (window, expectFull) in [(4096, false), (131_072, true)] {
        let provider = CountingProvider(window: window, steps: [selection("none"),
            .init([.toolCall(ToolCall(id: "r1", name: "read_skill", arguments: .object(["id": .string("big")]))), .completed(.toolCalls)]), text("看完了。")])
        let s = try await run(provider, text: "介绍一下大技能", skills: [longSkill()])
        let result = s.messages.first { $0.role == .tool && $0.toolCallId == "r1" }?.text ?? ""
        #expect(s.state == .completed, "window \(window): \(s.failure ?? "")")
        #expect(result.contains("这是一条很长的使用说明。") == expectFull && result.contains("【短说明】") == !expectFull, "window \(window)")
    }
}

@Test func withoutAnExactCounterTheEstimateDecidesWithALargerMargin() async throws {
    let provider = CountingProvider(window: 4096, exact: false, steps: [selection("big"), text("好的。")])
    let s = try await run(provider, text: "给我看看", skills: [longSkill()], thinking: true)
    let report = s.contextReports!.last { $0.kind == "step" }!
    #expect(s.state == .completed && !report.exact && report.promptTokens + report.reservedOutput <= 4096, "\(report)")
}

@Test func theEstimatorNeverUndercountsRealTextByMoreThanAboutTenPercent() {
    // Real Qwen3.5 token counts (tokenizer.json, 2026-10-31) for text of each kind. The estimate includes +4 message overhead, removed here.
    let samples: [(String, String, Int)] = [
        ("chineseProse", "我们在这个季度完成了三项重要的改进：第一，把对话历史的管理方式改成了先总结再压缩；第二，让模型在需要的时候才去读取技能的完整说明；第三，把输出长度的预留改成按提示实际占用来计算。这些改动的目的，是让一句很短的请求也不会因为上下文太长而失败。", 66),
        ("englishProse", "The quick brown fox jumps over the lazy dog while the committee reviews the quarterly budget, and nobody notices that the meeting has been moved to three o'clock on Thursday afternoon.", 34),
        ("jsonUI", "{\"id\":\"quiz1\",\"state\":{\"q1\":\"\",\"q2\":\"\"},\"root\":{\"type\":\"card\",\"title\":\"小测验\",\"children\":[{\"type\":\"text\",\"value\":\"1. 题目内容？\"},{\"type\":\"chips\",\"options\":[\"A. 选项一\",\"B. 选项二\",\"C. 选项三\"],\"bind\":\"q1\"},{\"type\":\"button\",\"label\":\"提交\",\"style\":\"primary\",\"action\":{\"type\":\"send\",\"text\":\"第1题我选 {{q1}}\"}}]}}", 103),
        ("swiftCode", "func fit(_ messages: [ModelMessage], budget: Int) -> Outcome {\n    var out = messages\n    while total(out) > budget, let i = out.firstIndex(where: { $0.role == .tool && $0.text.count > 400 }) {\n        out[i].text = String(out[i].text.prefix(400)) + \"…\"\n    }\n    return Outcome(messages: out, fits: total(out) <= budget)\n}", 100),
        ("mixed", "把这个 meeting 改到下午 3 点，然后给 alice@example.com 发一封邮件，主题是 Q3 review，附上 2026-10-31 的 report.pdf（约 4.2MB）。", 50),
        ("digitsAndIds", "订单 2026103112345678 已于 2026-10-31T16:47:06Z 创建，金额 1,299.00 元，追踪号 SF1234567890123，设备 UDID 00008140-000648D12E60801C。", 104),
        ("toolSchema", "{\"type\":\"function\",\"function\":{\"name\":\"weather_forecast\",\"description\":\"查询某地未来几天的天气预报\",\"parameters\":{\"type\":\"object\",\"properties\":{\"place\":{\"type\":\"string\",\"description\":\"城市名，例如 杭州\"},\"days\":{\"type\":\"integer\",\"description\":\"天数 1-7\"}},\"required\":[\"place\"]}}}", 65),
    ]
    for (name, text, real) in samples {
        let estimate = TokenEstimator.tokens(text) - 4
        #expect(Double(estimate) >= Double(real) * 0.9, "\(name): estimate \(estimate) under-counts real \(real)")
        #expect(Double(estimate) <= Double(real) * 2.0, "\(name): estimate \(estimate) over-counts real \(real) by more than 2x")
    }
}

@Test func outputRoomAndSkillBudgetFollowTheWindow() {
    #expect(OutputReservation.minimum(thinking: true, window: 4096) == 768 && OutputReservation.minimum(thinking: false, window: 4096) == 256)
    #expect(OutputReservation.allowance(window: 4096, prompt: 604, desired: 2048, margin: 64) == 2048, "a short prompt leaves the full thinking allowance")
    #expect(OutputReservation.allowance(window: 4096, prompt: 3300, desired: 2048, margin: 64) == 732, "a long prompt leaves what is left, not a fixed amount")
    #expect(SkillBudget.promptTokens(window: 4096) == 819 && SkillBudget.promptTokens(window: 8192) == 1638 && SkillBudget.promptTokens(window: 262_144) == 4000)
}

@Test func aFailedTurnStaysVisibleAsANoteAndRepeatedFailedRequestsCollapse() async throws {
    let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
    let c = try await s.createConversation()
    try await s.append(userMsg(c.id, "先聊聊周末的安排"))
    try await s.append(botMsg(c.id, "好的，周六去西湖。"))
    for _ in 0..<3 {
        try await s.append(userMsg(c.id, "渲染几个选择题出来"))
        try await s.append(.init(conversationId: c.id, role: .assistant, parts: [.text("内容太长")], status: .failed))
    }
    try await s.append(userMsg(c.id, "continue"))
    let b = try await cm.build(conversationId: c.id, budget: ContextBudget(contextWindow: 4096, reservedOutput: 512), supportsVision: false)
    let texts = b.messages.map(\.text)
    #expect(texts.filter { $0 == "渲染几个选择题出来" }.count == 1, "identical failed requests collapse to the latest: \(texts)")
    #expect(texts.filter { $0 == ContextManager.unfinishedNote }.count == 1 && !texts.contains("内容太长"))
    #expect(texts.first == "先聊聊周末的安排" && texts.last == "continue", "earlier turns and the new message are kept in order")
    let roles = b.messages.map(\.role)
    #expect(roles == [.user, .assistant, .user, .assistant, .user], "\(roles)")
}
