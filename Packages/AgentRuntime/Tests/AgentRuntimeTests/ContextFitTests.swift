import Testing
import Foundation
@testable import AgentRuntime

@Suite struct ContextFitTests {
    private func call(_ id: String, _ name: String = "web_search") -> ToolCall { ToolCall(id: id, name: name, arguments: .object(["q": .string("x")])) }
    private func pairs(_ ms: [ModelMessage]) -> Bool {
        var open = Set<String>()
        for m in ms {
            if m.role == .assistant { for c in m.toolCalls { open.insert(c.id) } }
            if m.role == .tool { guard let id = m.toolCallId, open.remove(id) != nil else { return false } }
        }
        return open.isEmpty
    }
    /// system, 6 earlier turns (some with tool calls), then the current turn with two tool steps.
    private func conversation(bigResult: Int = 3000) -> [ModelMessage] {
        var ms = [ModelMessage(role: .system, text: "你是助手。" + String(repeating: "规则。", count: 20)), ModelMessage(role: .system, text: "【较早对话的摘要】我对花生过敏。")]
        for i in 0..<6 {
            ms.append(.init(role: .user, text: "第\(i)轮问题：" + String(repeating: "内容", count: 80)))
            if i % 2 == 0 {
                ms.append(.init(role: .assistant, text: "", toolCalls: [call("old\(i)")]))
                ms.append(.init(role: .tool, text: String(repeating: "旧结果", count: 300), toolCallId: "old\(i)"))
            }
            ms.append(.init(role: .assistant, text: "第\(i)轮回答：" + String(repeating: "回答", count: 80)))
        }
        ms.append(.init(role: .user, text: "现在帮我查一下杭州明天的天气并总结"))
        ms.append(.init(role: .assistant, text: "", toolCalls: [call("s1")]))
        ms.append(.init(role: .tool, text: String(repeating: "结果一", count: bigResult / 3), toolCallId: "s1"))
        ms.append(.init(role: .assistant, text: "", toolCalls: [call("s2")]))
        ms.append(.init(role: .tool, text: String(repeating: "结果二", count: bigResult / 3), toolCallId: "s2"))
        return ms
    }

    @Test func underBudgetIsUntouched() {
        let ms = conversation(bigResult: 30)
        let out = ContextFit.fit(ms, budgetTokens: 100_000)
        #expect(out.messages == ms && !out.changed && out.fits)
    }

    @Test func shortensOldResultsBeforeDroppingAnythingAndKeepsPairs() {
        let ms = conversation()
        let budget = ContextFit.total(ms) - 1500
        let out = ContextFit.fit(ms, budgetTokens: budget)
        #expect(out.fits && out.droppedMessages == 0, "shortening old results alone is enough: \(out)")
        #expect(out.shortenedResults > 0 && pairs(out.messages))
        #expect(out.messages.count == ms.count)
        #expect(out.messages.last?.text == ms.last?.text, "the latest step is untouched while older material can still give")
    }

    @Test func dropsWholeOlderTurnsOldestFirstWhenShorteningIsNotEnough() {
        let ms = conversation()
        let budget = 1400
        let out = ContextFit.fit(ms, budgetTokens: budget)
        #expect(out.fits, "\(out.tokensAfter) > \(budget)")
        #expect(pairs(out.messages), "no orphaned tool call or result")
        #expect(out.messages.prefix(2).allSatisfy { $0.role == .system } && out.messages[1].text.contains("花生过敏"), "instructions and summary stay")
        let users = out.messages.filter { $0.role == .user }.map(\.text)
        #expect(users.last == "现在帮我查一下杭州明天的天气并总结")
        #expect(!users.contains { $0.hasPrefix("第0轮") }, "the oldest turn goes first")
        // what remains of the earlier turns is a suffix of them: nothing from the middle disappears while older turns stay
        let kept = users.dropLast().map { Int($0.dropFirst().prefix(1)) ?? -1 }
        #expect(kept == kept.sorted() && (kept.isEmpty || kept.last == 5), "\(kept)")
    }

    @Test func theCurrentTurnIsOnlyShortenedNeverDropped() {
        let ms = conversation(bigResult: 9000)
        let out = ContextFit.fit(ms, budgetTokens: 900)
        #expect(pairs(out.messages))
        let tail = out.messages.suffix(5)
        #expect(tail.first?.role == .user && tail.filter { $0.role == .tool }.count == 2, "both steps of the current turn survive")
        #expect(out.tokensAfter < out.tokensBefore)
    }

    @Test func reportsHonestlyWhenItCannotFit() {
        let ms = [ModelMessage(role: .system, text: String(repeating: "系统提示", count: 600)), ModelMessage(role: .user, text: "你好")]
        let out = ContextFit.fit(ms, budgetTokens: 200)
        #expect(!out.fits && out.messages.count == 2, "system text is never cut; the caller must say the request is too large")
    }

    @Test func protectedHistoryIsNotDroppedToMakeAnOversizedRequestFit() {
        let ms = [ModelMessage(role: .system, text: "你是助手"),
                  ModelMessage(role: .user, text: String(repeating: "重要的背景", count: 300)),
                  ModelMessage(role: .assistant, text: "我记住了"),
                  ModelMessage(role: .user, text: "继续")]
        let out = ContextFit.fit(ms, budgetTokens: 200, allowOlderTurnDrop: false)
        #expect(!out.fits && out.messages == ms && out.droppedMessages == 0)
    }

    @Test func anOversizedCurrentRequestIsPreservedAndReportedAsTooLarge() {
        let paste = "开头：重要问题" + String(repeating: "很长的材料", count: 2000) + "结尾：请总结"
        let ms = [ModelMessage(role: .system, text: "你是助手"), ModelMessage(role: .user, text: paste)]
        let out = ContextFit.fit(ms, budgetTokens: 2000)
        #expect(!out.fits)
        #expect(out.messages[1].text == paste)
        #expect(!out.changed)
    }

    @Test func deterministicAndIdempotent() {
        let ms = conversation()
        let a = ContextFit.fit(ms, budgetTokens: 1500), b = ContextFit.fit(ms, budgetTokens: 1500)
        #expect(a == b)
        let again = ContextFit.fit(a.messages, budgetTokens: 1500)
        #expect(again.messages == a.messages && !again.changed)
    }

    @Test func englishAndMixedTextFollowTheEstimator() {
        var ms = [ModelMessage(role: .system, text: "You are helpful."), ModelMessage(role: .user, text: "Summarize the page")]
        ms.append(.init(role: .assistant, text: "", toolCalls: [call("a")]))
        ms.append(.init(role: .tool, text: String(repeating: "lorem ipsum dolor sit amet ", count: 400), toolCallId: "a"))
        let out = ContextFit.fit(ms, budgetTokens: 600)
        #expect(out.fits && pairs(out.messages) && out.messages.last?.text.contains("已省略") == true)
    }

    @Test func budgetLeavesRoomForTheReplyAndToolSchemas() {
        #expect(ContextFit.budget(contextWindow: 4096, reservedOutput: 512, toolSchemaTokens: 600) == Int(4096.0 * 0.8) - 512 - 600)
        #expect(ContextFit.budget(contextWindow: 1000, reservedOutput: 900, toolSchemaTokens: 900) == 256)
    }
}

// MARK: - The runner applies the fitter to every model step

private struct BigReadFixture: AgentTool {
    let spec = ToolSpec(name: "big_read", description: "读取一大段资料", parameters: [:], permission: .readOnly, capability: .web, systemPermission: .none, dataClass: .general)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(value: .object(["text": .string(String(repeating: "很长的网页内容。", count: 700))]), summary: "已读取")
    }
}

@Test func everyModelStepFitsTheProvidersWindowAndKeepsToolPairsIntact() async throws {
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "bigread", name: "资料", summary: "读取资料", instructions: "", toolNames: ["big_read"]))
    let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [
        .init([.toolCall(ToolCall(id: "l1", name: "load_skill", arguments: .object(["id": .string("bigread")]))), .completed(.toolCalls)]),
        .init([.toolCall(ToolCall(id: "b1", name: "big_read", arguments: .object([:]))), .completed(.toolCalls)]),
        .init([.textDelta("总结完成"), .usage(Usage(promptTokens: 10, completionTokens: 5, providerId: "scripted")), .completed(.stop)])
    ])
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([BigReadFixture()]), skills: catalog, store: InMemoryRunStore(), granted: { allCaps })
    let id = try await runner.start(conversationId: UUID(), text: "读一下这个网页并总结")
    await runner.waitUntilIdle(id)
    let snapshot = await runner.snapshot(id)!
    #expect(snapshot.state == .completed && snapshot.finalText == "总结完成")
    let window = provider.descriptor.capabilities.contextWindow
    for request in provider.requests {
        let tokens = request.messages.reduce(0) { $0 + ContextFit.tokens($1) }
        #expect(tokens <= Int(Double(window) * 0.8), "a request of \(tokens) estimated tokens does not fit a \(window) window")
        var open = Set<String>()
        for m in request.messages {
            if m.role == .assistant { for c in m.toolCalls { open.insert(c.id) } }
            if m.role == .tool, let id = m.toolCallId { #expect(open.remove(id) != nil, "tool result without its call") }
        }
        #expect(open.isEmpty, "tool call without its result")
    }
    let last = provider.requests.last!.messages.last { $0.role == .tool && $0.toolCallId == "b1" }
    #expect(last?.text.contains("已省略") == true, "the huge page was shortened, not dropped: \(last?.text.count ?? 0) characters")
}

@Test func aRequestThatCannotFitTheWindowAtAllFailsHonestlyInsteadOfBeingSent() async throws {
    let tiny = ModelDescriptor(id: "tiny", kind: .localDownloaded, displayName: "tiny",
                               capabilities: ProviderCapabilities(contextWindow: 300, toolCalling: .native, structuredOutput: false, maxAutonomy: .fullAgent, worksOffline: true, sendsContentOffDevice: false))
    let provider = ScriptedModelProvider(descriptor: tiny, steps: [.init([.textDelta("不应该被调用"), .completed(.stop)])])
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([]), store: InMemoryRunStore(), granted: { allCaps })
    let id = try await runner.start(conversationId: UUID(), text: "你好")
    await runner.waitUntilIdle(id)
    let snapshot = await runner.snapshot(id)!
    #expect(snapshot.state == .failed && snapshot.failure == "context_too_large" && provider.requests.isEmpty, "\(snapshot.state) \(snapshot.failure ?? "-")")
}

@Test func oneToolCalledAgainAndAgainWithNewArgumentsIsStoppedAndTheRunAnswersWithWhatItHas() async throws {
    let steps = (0..<4).map { call("c\($0)", "calculate", .object(["expression": .string("\($0 + 1)+1")])) } + [text("我只算了前三个，先告诉你这些。")]
    let (r, p, _) = makeRunner(steps)
    let id = try await r.start(conversationId: UUID(), text: "把这些都算一下")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.toolCalls == 3 && s.finalText == "我只算了前三个，先告诉你这些。", "\(s.state) calls=\(s.toolCalls)")
    let last = p.requests.last!
    #expect(last.messages.first?.text.contains("现在不能再调用任何工具") == true && last.tools.isEmpty, "the final step is a tool-free answer step")
}

private struct SleepFixture: AgentTool {
    let spec = ToolSpec(name: "health_sleep", description: "读取睡眠", parameters: [:], permission: .readOnly, capability: .health, systemPermission: .health, dataClass: .sensitive)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput { ToolOutput(value: .object(["hours": .number(7.5)]), summary: "睡眠 7.5 小时") }
}

@Test func anAnswerThatStatesFiguresAfterEveryToolSaidItCouldNotReadThemIsReplacedByTheTruth() async throws {
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "health", name: "健康", summary: "读取睡眠", instructions: "", toolNames: ["health_sleep"]))
    func run(permission: PermissionState, answer: String) async throws -> RunSnapshot {
        let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [call("l", "load_skill", .object(["id": .string("health")])), call("s", "health_sleep", .object([:])), text(answer)])
        let runner = AgentRunner(provider: provider, tools: ToolRegistry([SleepFixture()]), skills: catalog, store: InMemoryRunStore(), permissions: StaticPermissionAuthority(system: [.health: permission]))
        let id = try await runner.start(conversationId: UUID(), text: "我昨晚睡了多久？")
        await runner.waitUntilIdle(id)
        return await runner.snapshot(id)!
    }
    let invented = try await run(permission: .denied, answer: "你昨晚大约睡了 8 小时，睡眠质量不错。")
    #expect(invented.state == .completed && invented.finalText?.contains("没能读取到") == true && invented.finalText?.contains("8") == false, "\(invented.finalText ?? "")")
    let honest = try await run(permission: .denied, answer: "我没有读取健康数据的权限，所以无法告诉你睡了多久。")
    #expect(honest.finalText == "我没有读取健康数据的权限，所以无法告诉你睡了多久。", "an honest answer is left alone")
    let real = try await run(permission: .granted, answer: "你昨晚睡了 7.5 小时。")
    #expect(real.finalText == "你昨晚睡了 7.5 小时。", "figures that came from a tool are fine")
}
