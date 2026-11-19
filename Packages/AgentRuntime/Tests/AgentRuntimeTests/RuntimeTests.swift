import Foundation
import Testing
@testable import AgentRuntime

// MARK: helpers

final class FakeReminders: ReminderStore, @unchecked Sendable {
    private let lock = NSLock()
    var created: [String: String] = [:]   // key -> id
    var createCalls = 0
    func create(title: String, due: Date?, idempotencyKey: String) async throws -> String {
        lock.withLock { createCalls += 1; if let id = created[idempotencyKey] { return id }; let id = "rem-\(created.count + 1)"; created[idempotencyKey] = id; return id }
    }
    func exists(idempotencyKey: String) async -> String? { lock.withLock { created[idempotencyKey] } }
    func verify(id: String) async -> Bool { lock.withLock { created.values.contains(id) } }
    func preload(_ key: String) { lock.withLock { created[key] = "rem-pre" } }
}

let allCaps: Set<Capability> = Set(Capability.allCases).subtracting([.cloudPersonalData, .cloudHealthData])
func text(_ s: String) -> ScriptedModelProvider.Step { .init([.textDelta(s), .usage(Usage(promptTokens: 10, completionTokens: 5, providerId: "scripted")), .completed(.stop)]) }
func call(_ id: String, _ name: String, _ args: JSONValue) -> ScriptedModelProvider.Step {
    .init([.toolCall(ToolCall(id: id, name: name, arguments: args)), .completed(.toolCalls)])
}
func makeRunner(_ steps: [ScriptedModelProvider.Step], store: (any RunStore)? = nil, reminders: FakeReminders = FakeReminders(), autonomy: AutonomyLevel = .fullAgent,
                caps: Set<Capability> = allCaps, now: @escaping @Sendable () -> Date = { .now }) -> (AgentRunner, ScriptedModelProvider, FakeReminders) {
    let p = ScriptedModelProvider(descriptor: .scripted(autonomy: autonomy), steps: steps)
    let r = AgentRunner(provider: p, tools: ToolRegistry([DateTimeTool(), CalculatorTool(), CreateReminderTool(store: reminders)]),
                        store: store ?? InMemoryRunStore(), granted: { caps }, now: now)
    return (r, p, reminders)
}
func settle(_ r: AgentRunner, _ id: UUID) async { await r.waitUntilIdle(id) }

@Test func repeatingLocalThinkingRetriesOnceWithoutThinking() async throws {
    let phrase = "我需要检查问题并选择正确的工具，然后继续处理。"
    let loop = ScriptedModelProvider.Step((0..<12).map { _ in .reasoningDelta(phrase) }, delayMs: 1)
    let (runner, provider, _) = makeRunner([loop, text("这是结果。")])
    await runner.setReasoning(true)
    let id = try await runner.start(conversationId: UUID(), text: "请回答")
    await settle(runner, id)
    let snapshot = await runner.snapshot(id)
    #expect(snapshot?.state == .completed && snapshot?.finalText == "这是结果。")
    #expect(provider.requests.map(\.reasoning) == [true, false])
}

@Test func reasoningLoopGuardDoesNotInterruptActualAnswerOrCloudGeneration() async throws {
    let repeated = String(repeating: "一段重复的思考内容用于检验流式循环检测。", count: 12)
    let withAnswer = ScriptedModelProvider.Step([.textDelta("回答"), .reasoningDelta(repeated), .completed(.stop)])
    let (localRunner, localProvider, _) = makeRunner([withAnswer])
    await localRunner.setReasoning(true)
    let localID = try await localRunner.start(conversationId: UUID(), text: "请回答")
    await settle(localRunner, localID)
    #expect(localProvider.requests.count == 1)
    #expect(await localRunner.snapshot(localID)?.finalText == "回答")

    let cloud = ScriptedModelProvider(descriptor: .scripted(kind: .cloudGateway, offline: false), steps: [
        .init([.reasoningDelta(repeated), .textDelta("云端回答"), .completed(.stop)])
    ])
    let cloudRunner = AgentRunner(provider: cloud, tools: ToolRegistry([]), store: InMemoryRunStore(), granted: { allCaps })
    await cloudRunner.setCloudReasoning(true)
    let cloudID = try await cloudRunner.start(conversationId: UUID(), text: "请回答")
    await settle(cloudRunner, cloudID)
    #expect(cloud.requests.count == 1)
    #expect(await cloudRunner.snapshot(cloudID)?.finalText == "云端回答")
}

@Test func repeatedLocalAnswerStopsWithoutClaimingSuccessOrRetryingTools() async throws {
    let phrase = "游戏、聊天、翻译、写作、搜索、分析、绘画、"
    let repeated = ScriptedModelProvider.Step([.textDelta("```italk-ui\n{\"options\":[\"")] + (0..<40).map { _ in .textDelta(phrase) }, delayMs: 1)
    let (runner, provider, _) = makeRunner([repeated])
    let id = try await runner.start(conversationId: UUID(), text: "渲染选择题")
    await settle(runner, id)
    let snapshot = await runner.snapshot(id)
    #expect(snapshot?.state == .failed && snapshot?.failure == "repetitive_output")
    #expect(snapshot?.finalText == nil && snapshot?.toolCalls == 0 && provider.requests.count == 1)
}

@Test func validInteractiveAnswerKeepsItsMarkdownFences() async throws {
    let card = "```italk-ui\n{\"id\":\"quiz\",\"root\":{\"type\":\"text\",\"value\":\"题目\"}}\n```"
    let (runner, _, _) = makeRunner([text(card)])
    let id = try await runner.start(conversationId: UUID(), text: "渲染选择题")
    await settle(runner, id)
    #expect(await runner.snapshot(id)?.finalText == card)
}

@Test func instructionOnlyInterfaceSkillIsDiscoverableByCloudModels() async throws {
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "generative_ui", name: "交互界面", summary: "生成交互界面", instructions: "使用 italk-ui 代码块", toolNames: []))
    let provider = ScriptedModelProvider(descriptor: .scripted(kind: .cloudGateway, offline: false), steps: [
        call("skill", "read_skill", .object(["id": .string("generative_ui")])),
        text("```italk-ui\n{\"id\":\"quiz\",\"root\":{\"type\":\"text\",\"value\":\"题目\"}}\n```")
    ])
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([]), skills: catalog, store: InMemoryRunStore(), granted: { allCaps })
    let id = try await runner.start(conversationId: UUID(), text: "渲染几个选择题出来我看看你的skills")
    await settle(runner, id)
    #expect(provider.requests.first?.messages.first?.text.contains("generative_ui") == true)
    #expect(provider.requests.count == 2)
    #expect(provider.requests.first?.maxTokens == 512)
    #expect(provider.requests.last?.maxTokens == 2048)
    #expect(provider.requests.last?.messages.contains(where: { $0.role == .tool && $0.text.contains("italk-ui") }) == true)
    #expect(await runner.snapshot(id)?.finalText?.contains("```italk-ui") == true)
}

@Test func skillTextOverridesKeepToolsAndPermissionsAndClearStaleBrief() throws {
    let original = Skill(id: "test", name: "测试", summary: "原简介", instructions: "原说明", toolNames: ["read"], limitations: "限制", trust: .builtIn, brief: "旧摘要")
    let edited = SkillTextOverride(summary: "新简介", instructions: "新说明").applying(to: original)
    #expect(edited.summary == "新简介" && edited.instructions == "新说明" && edited.brief == nil)
    #expect(edited.toolNames == original.toolNames && edited.trust == original.trust && edited.limitations == original.limitations)
    let roundTrip = try JSONDecoder().decode(SkillTextOverride.self, from: JSONEncoder().encode(SkillTextOverride(summary: edited.summary, instructions: edited.instructions)))
    #expect(roundTrip.applying(to: original) == edited)
}

private struct LocationReadFixture: AgentTool {
    let spec = ToolSpec(name: "location_current", description: "当前位置", parameters: ["precise": ParamSpec(.boolean, "精确", required: false)],
                        permission: .readOnly, capability: .location, systemPermission: .location, dataClass: .personal)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        ToolOutput(value: .object(["city": .string("fixture")]), summary: "已获取位置")
    }
}

@Test func loadedReadToolNamedAsSkillRunsThroughPermissionGate() async throws {
    for permission in [PermissionState.granted, .denied] {
        var catalog = SkillCatalog.standard
        catalog.add(Skill(id: "location", name: "位置", summary: "当前位置", instructions: "", toolNames: ["location_current"]))
        let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [
            call("skill", "load_skill", .object(["id": .string("location")])),
            call("location", "load_skill", .object(["id": .string("location_current")])), text("完成")
        ])
        let runner = AgentRunner(provider: provider, tools: ToolRegistry([LocationReadFixture()]), skills: catalog,
                                 store: InMemoryRunStore(), permissions: StaticPermissionAuthority(system: [.location: permission]))
        let id = try await runner.start(conversationId: UUID(), text: "我在哪里")
        await settle(runner, id)
        let snapshot = await runner.snapshot(id)!
        #expect(snapshot.modelSteps == 3)
        #expect(snapshot.toolCalls == (permission == .granted ? 1 : 0))
        let result = snapshot.messages.last { $0.role == .tool && $0.toolCallId == "location" }
        #expect(result != nil)
        if permission == .granted { #expect(result?.text.contains("fixture") == true) }
        else { #expect(result?.text.contains("permission_unavailable") == true) }
    }
}

@Test func skillNameMistakeNeverExecutesSideEffects() async throws {
    let reminders = FakeReminders()
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "reminders", name: "提醒", summary: "提醒", instructions: "", toolNames: ["create_reminder"]))
    let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [
        call("skill", "load_skill", .object(["id": .string("reminders")])),
        call("action", "load_skill", .object(["id": .string("create_reminder")])), text("请提供标题")
    ])
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([CreateReminderTool(store: reminders)]), skills: catalog,
                             store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
    let id = try await runner.start(conversationId: UUID(), text: "提醒我")
    await settle(runner, id)
    #expect(reminders.createCalls == 0)
    #expect((await runner.snapshot(id))?.toolCalls == 0)
}

@Test func repeatedSkillDiscoveryStopsBeforeBudgetIsExhausted() async throws {
    let args = JSONValue.object(["id": .string("core")])
    let (runner, _, _) = makeRunner([call("one", "load_skill", args), call("two", "load_skill", args),
                                     call("three", "load_skill", args), text("无法继续")])
    let id = try await runner.start(conversationId: UUID(), text: "测试")
    await settle(runner, id)
    let snapshot = await runner.snapshot(id)!
    #expect(snapshot.modelSteps == 4)
    #expect(snapshot.messages.contains { $0.role == .tool && $0.toolCallId == "three" && $0.text.contains("重复这个调用") })
}

// MARK: contracts

@Test func stateMachineRejectsIllegalTransitions() {
    #expect(RunState.completed.canTransition(to: .running) == false)
    #expect(RunState.awaitingApproval.canTransition(to: .running))
    #expect(RunState.created.canTransition(to: .completed) == false)
    #expect(RunState.suspended.canTransition(to: .running) == false)
    #expect(RunState.allCases.count == 14)
}

@Test func parserHidesToolMarkupAcrossChunkBoundaries() {
    var p = ToolCallTextParser()
    var out = ToolCallTextParser.Output()
    for chunk in ["好的<tool", "_call>{\"name\":\"calc", "ulate\",\"arguments\":{\"expression\":\"1+1\"}}</tool_", "call>结果", "是2"] {
        let o = p.feed(chunk); out.text += o.text; out.calls += o.calls; out.malformed += o.malformed
    }
    let f = p.finish(); out.text += f.text
    #expect(out.text == "好的结果是2")
    #expect(out.calls.count == 1 && out.calls[0].name == "calculate")
    #expect(out.calls[0].arguments["expression"]?.string == "1+1")
}

@Test func parserDiscardsUnterminatedAndMalformedCalls() {
    var p = ToolCallTextParser()
    let a = p.feed("x<tool_call>not json</tool_call>y<tool_call>{\"name\":\"a\"")
    let b = p.finish()
    #expect(a.text == "xy" && a.malformed == 1 && a.calls.isEmpty)
    #expect(b.malformed == 1 && b.text.isEmpty)
    var q = ToolCallTextParser()
    #expect(q.feed("a < b").text + q.finish().text == "a < b")
}

@Test func toolValidationIsStrict() throws {
    let spec = CreateReminderTool(store: FakeReminders()).spec
    try spec.validate(.object(["title": .string("x")]))
    #expect(throws: ToolValidationError.unknownArgument("evil")) { try spec.validate(.object(["title": .string("x"), "evil": .bool(true)])) }
    #expect(throws: ToolValidationError.missing("title")) { try spec.validate(.object([:])) }
    #expect(throws: ToolValidationError.wrongType("title")) { try spec.validate(.object(["title": .number(3)])) }
    #expect(throws: ToolValidationError.tooLong("title")) { try spec.validate(.object(["title": .string(String(repeating: "a", count: 201))])) }
}

@Test func calculatorHandlesPrecedenceAndRejectsGarbage() {
    #expect(ArithmeticParser.evaluate("2+3*4") == 14)
    #expect(ArithmeticParser.evaluate("(2+3)*4") == 20)
    #expect(ArithmeticParser.evaluate("10/4") == 2.5)
    #expect(ArithmeticParser.evaluate("1/0") == nil)
    #expect(ArithmeticParser.evaluate("system(\"ls\")") == nil)
    #expect(ArithmeticParser.evaluate("2+") == nil)
}

@Test func eventsRoundTripAndRedact() throws {
    let e = AgentEvent(eventId: UUID(), runId: UUID(), conversationId: UUID(), stepId: "s", parentId: nil, sequence: 1, timestamp: Date(timeIntervalSince1970: 0),
                       type: .modelDelta, visibility: .content, payload: .textDelta("我的血压是120"))
    let data = try AgentCoding.encoder().encode(e)
    #expect(try AgentCoding.decoder().decode(AgentEvent.self, from: data) == e)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("\"schemaVersion\":1") && json.contains("model.output.delta"))
    let red = String(data: try AgentCoding.encoder().encode(e.redacted()), encoding: .utf8)!
    #expect(!red.contains("血压"))
}

// MARK: routing (local first)

@Test func freeUserNeverRoutesToCloudSilently() {
    let local = ModelDescriptor.scripted(id: "qwen-2b")
    let cloud = ModelDescriptor.scripted(id: "cloud", kind: .cloudGateway, offline: false)
    let router = ModelRouter(installed: [local], cloud: cloud)
    #expect(router.route(policy: .init(), context: .init()) == .use(local))
    // Local unusable (e.g. thermal): offer, never auto-send.
    #expect(router.route(policy: .init(), context: .init(localUsable: false)) == .needsUserChoice(.localUnavailableOfferCloud))
    #expect(router.route(policy: .init(cloudEnabled: true), context: .init(userRequestedCloud: true)) == .needsUserChoice(.cloudNeedsConsent))
    #expect(router.route(policy: .init(cloudEnabled: true, cloudConsentGranted: true), context: .init(userRequestedCloud: true)) == .needsUserChoice(.cloudNeedsSubscription))
    let paid = ModelPolicy(cloudEnabled: true, cloudConsentGranted: true, cloudEntitled: true)
    #expect(router.route(policy: paid, context: .init(userRequestedCloud: true)) == .use(cloud))
    #expect(router.route(policy: paid, context: .init(involvesHealthData: true, userRequestedCloud: true)) == .needsUserChoice(.cloudHealthNeedsConsent))
    // Subscription lapsed: local keeps working.
    var lapsed = paid; lapsed.cloudEntitled = false
    #expect(router.route(policy: lapsed, context: .init()) == .use(local))
    #expect(ModelRouter(installed: [], cloud: cloud).route(policy: .init(), context: .init()) == .needsUserChoice(.localUnavailableOfferCloud))
    #expect(ModelRouter(installed: [], cloud: nil).route(policy: .init(), context: .init()) == .needsUserChoice(.noLocalModelInstalled))
}

// MARK: runner

@Test func plainConversationStreamsAndCompletes() async throws {
    let (r, p, _) = makeRunner([text("你好，我是 iTalk。")])
    let conv = UUID()
    let stream = await r.bus.subscribe()
    let id = try await r.start(conversationId: conv, text: "你好")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "你好，我是 iTalk。")
    #expect(s.usage.first?.completionTokens == 5)
    var types: [AgentEventType] = []
    for await e in stream { types.append(e.type); if e.type == .runCompleted { break } }
    #expect(types.contains(.runCreated) && types.contains(.modelDelta) && types.contains(.usageUpdated))
    #expect(p.requests.count == 1)
}

@Test func multiStepRunExecutesRealToolAndFeedsResultBack() async throws {
    let (r, p, _) = makeRunner([call("c1", "calculate", .object(["expression": .string("12*(3+4)")])), text("结果是84。")])
    let id = try await r.start(conversationId: UUID(), text: "帮我算一下十二乘七")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "结果是84。" && s.toolCalls == 1)
    let second = p.requests[1].messages
    #expect(second.last?.role == .tool && second.last?.text.contains("84") == true)
    #expect(second.last?.text.contains("仅为资料") == true)
}

@Test func reminderRequiresApprovalThenCreatesAndVerifies() async throws {
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("喝水")])), text("已创建提醒。")])
    let id = try await r.start(conversationId: UUID(), text: "提醒我喝水")
    await settle(r, id)
    var s = await r.snapshot(id)!
    #expect(s.state == .awaitingApproval && rem.createCalls == 0)
    let pending = s.pending!, comp = s.components[pending.componentId]!.component
    guard case .approval(let name, let summary, _) = comp.content else { Issue.record("not approval"); return }
    #expect(name == "create_reminder" && summary.contains("喝水"))
    try await r.submit(UIActionResponse(runId: id, componentId: comp.id, componentRevision: comp.revision, actionId: "approve", idempotencyKey: "k1"))
    await settle(r, id)
    s = await r.snapshot(id)!
    #expect(s.state == .completed && rem.createCalls == 1 && s.components[comp.id]?.status == .completed)
    #expect(s.sideEffects.values.first?.status == .completed)
}

@Test func declinedApprovalNeverExecutes() async throws {
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")])), text("好的，没有创建。")])
    let id = try await r.start(conversationId: UUID(), text: "提醒我x")
    await settle(r, id)
    let s = await r.snapshot(id)!, c = s.components[s.pending!.componentId]!.component
    try await r.submit(UIActionResponse(runId: id, componentId: c.id, componentRevision: 1, actionId: "decline", idempotencyKey: "k", authorization: .none))
    await settle(r, id)
    let snap3 = await r.snapshot(id)!
    #expect(rem.createCalls == 0 && snap3.state == .completed)
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@Test func cardActionsAreValidated() async throws {
    let clock = ClockBox()
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")])), text("完成")], now: { clock.now })
    let id = try await r.start(conversationId: UUID(), text: "提醒我x")
    await settle(r, id)
    let s = await r.snapshot(id)!, c = s.components[s.pending!.componentId]!.component
    func resp(rev: Int = 1, action: String = "approve", key: String = "k", auth: ActionAuthorization = .userTap, comp: String? = nil) -> UIActionResponse {
        UIActionResponse(runId: id, componentId: comp ?? c.id, componentRevision: rev, actionId: action, idempotencyKey: key, authorization: auth)
    }
    await #expect(throws: RunnerError.unknownRun) { try await r.submit(UIActionResponse(runId: UUID(), componentId: c.id, componentRevision: 1, actionId: "approve", idempotencyKey: "z")) }
    await #expect(throws: ActionRejection.noPendingInteraction) { try await r.submit(resp(comp: "other")) }
    await #expect(throws: ActionRejection.staleRevision) { try await r.submit(resp(rev: 0)) }
    await #expect(throws: ActionRejection.unknownAction) { try await r.submit(resp(action: "launch_missiles")) }
    await #expect(throws: ActionRejection.unauthorized) { try await r.submit(resp(auth: .none)) }
    clock.advance(10_000)
    await #expect(throws: ActionRejection.expired) { try await r.submit(resp()) }
    #expect(rem.createCalls == 0)
    await r.resume(id)
    let snap4 = await r.snapshot(id)!
    #expect(snap4.state == .expired)
}

@Test func duplicateAndReplayedActionsAreRejected() async throws {
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")])), text("完成")])
    let id = try await r.start(conversationId: UUID(), text: "提醒我x")
    await settle(r, id)
    let c = (await r.snapshot(id)!).components.values.first!.component
    let ok = UIActionResponse(runId: id, componentId: c.id, componentRevision: 1, actionId: "approve", idempotencyKey: "same")
    try await r.submit(ok)
    await settle(r, id)
    await #expect(throws: ActionRejection.self) { try await r.submit(ok) }
    #expect(rem.createCalls == 1)
}

@Test func cancellationStopsGenerationAndSuppressesStaleOutput() async throws {
    let slow = ScriptedModelProvider.Step((0..<50).map { .textDelta("字\($0)") } + [.completed(.stop)], delayMs: 20)
    let (r, _, _) = makeRunner([slow])
    let id = try await r.start(conversationId: UUID(), text: "讲个长故事")
    try await Task.sleep(for: .milliseconds(120))
    await r.cancel(id)
    await r.waitUntilIdle(id)
    let count = await r.bus.eventCount(id)
    try await Task.sleep(for: .milliseconds(200))
    let after = await r.bus.eventCount(id)
    let snap = await r.snapshot(id)!
    #expect(snap.state == .cancelled && snap.finalText == nil)
    #expect(after == count, "no deltas may be published after cancellation")
}

@Test func networkLossParksRunAndResumeCompletesIt() async throws {
    let (r, _, _) = makeRunner([.init([], error: .network), text("恢复了")])
    let id = try await r.start(conversationId: UUID(), text: "你好")
    await settle(r, id)
    let snap6 = await r.snapshot(id)!
    #expect(snap6.state == .awaitingNetwork)
    await r.resume(id)
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "恢复了")
}

@Test func partialToolStreamIsRetriedOnceThenFails() async throws {
    let broken = ScriptedModelProvider.Step([.textDelta("半")])  // ends without .completed
    let (r, p, _) = makeRunner([broken, text("完整")])
    var id = try await r.start(conversationId: UUID(), text: "hi")
    await settle(r, id)
    let snap7 = await r.snapshot(id)!
    #expect(snap7.state == .completed && p.requests.count == 2)
    let (r2, _, _) = makeRunner([broken, broken])
    id = try await r2.start(conversationId: UUID(), text: "hi")
    await settle(r2, id)
    let snap8 = await r2.snapshot(id)!
    #expect(snap8.state == .failed)
}

@Test func budgetStopsRunawayToolLoops() async throws {
    let looping = (0..<30).map { call("c\($0)", "calculate", .object(["expression": .string("1+1")])) }
    let (r, _, _) = makeRunner(looping)
    let id = try await r.start(conversationId: UUID(), text: "loop")
    await settle(r, id)
    let s = await r.snapshot(id)!
    // A runaway loop is stopped after a bounded number of steps and ends with an honest answer, not a bare failure.
    #expect(s.state == .completed && s.modelSteps <= 4)
    #expect(s.finalText?.contains("没能") == true && s.finalText?.contains("已完成") == false)
}

@Test func guidedSelectionLoadsTheChosenSkillBeforeTheFirstStep() async throws {
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "reminders", name: "提醒事项", summary: "创建提醒事项", instructions: "", toolNames: ["create_reminder"]))
    // step 1 answers the selector (a short question), step 2 is the real step: it calls the tool directly
    let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [text("reminders"), call("c1", "create_reminder", .object(["title": .string("喝水")])), text("好了")])
    var config = RunnerConfig(); config.skillSelectionOverride = .guided
    let reminders = FakeReminders()
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([CreateReminderTool(store: reminders)]), skills: catalog, store: InMemoryRunStore(),
                             permissions: StaticPermissionAuthority(), config: config)
    let id = try await runner.start(conversationId: UUID(), text: "提醒我喝水")
    await settle(runner, id)
    var s = await runner.snapshot(id)!
    #expect(s.selection == ["reminders"] && s.loadedSkills == ["reminders"])
    #expect(s.state == .awaitingApproval)
    let card = s.components[s.pending!.componentId]!.component
    try await runner.submit(UIActionResponse(runId: id, componentId: card.id, componentRevision: card.revision, actionId: "approve", idempotencyKey: "k"))
    await settle(runner, id)
    s = await runner.snapshot(id)!
    #expect(s.state == .completed && reminders.createCalls == 1)
    // the first real step saw the chosen tool and no discovery tools
    let requests = provider.requests
    #expect(requests.count >= 2)
    #expect(requests[1].tools.map(\.name) == ["create_reminder"])
    #expect(requests[0].tools.isEmpty)
}

@Test func guidedSelectionOnlyAcceptsCatalogIds() {
    let catalog = SkillCatalog.standard
    #expect(AgentRunner.parseSelection("core, reminders, core", skills: catalog) == ["core", "reminders"])
    #expect(AgentRunner.parseSelection("none", skills: catalog).isEmpty)
    #expect(AgentRunner.parseSelection("我觉得需要 hacker_skill 和 core。", skills: catalog) == ["core"])
    #expect(AgentRunner.parseSelection("Core\nreminders\ncore", skills: catalog) == ["core", "reminders"])
}

@Test func oneActiveRunPerConversation() async throws {
    let (r, _, _) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")]))])
    let conv = UUID()
    let id = try await r.start(conversationId: conv, text: "x")
    await settle(r, id)
    await #expect(throws: RunnerError.conversationBusy) { try await r.start(conversationId: conv, text: "y") }
}

@Test func crashAfterSideEffectReconcilesInsteadOfRepeating() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("italk-\(UUID())")
    let store = try FileRunStore(directory: dir)
    let (r1, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("吃药")])), text("已创建。")], store: store)
    let id = try await r1.start(conversationId: UUID(), text: "提醒我吃药")
    await settle(r1, id)
    // Simulate: user approved, side effect landed in the system store, process died before the checkpoint finished.
    var snap = await store.load(runId: id)!
    snap.approvals["c1"] = true; snap.pending = nil; snap.state = .awaitingTool
    snap.sideEffects["\(id)/c1"] = SideEffectRecord(status: .started, toolName: "create_reminder", output: nil)
    try await store.save(snap)
    rem.preload("\(id)/c1")
    // New process: fresh runner on the same disk store.
    let (r2, _, _) = makeRunnerSharing(store: store, reminders: rem, steps: [text("已创建。")])
    await r2.resume(id)
    await settle(r2, id)
    let s = await r2.snapshot(id)!
    #expect(s.state == .completed)
    #expect(rem.createCalls == 0, "must reconcile, not create again")
    #expect(s.sideEffects["\(id)/c1"]?.status == .completed)
}

@Test func unknownOutcomeIsNeverRetried() async throws {
    let store = InMemoryRunStore()
    let (r1, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")])), text("无法确认。")], store: store)
    let id = try await r1.start(conversationId: UUID(), text: "提醒我x")
    await settle(r1, id)
    var snap = await store.load(runId: id)!
    snap.approvals["c1"] = true; snap.pending = nil; snap.state = .awaitingTool
    snap.sideEffects["\(id)/c1"] = SideEffectRecord(status: .started, toolName: "create_reminder", output: nil)
    await (store as InMemoryRunStore).save(snap)
    let (r2, _, _) = makeRunnerSharing(store: store, reminders: rem, steps: [text("无法确认。")])
    await r2.resume(id)
    await settle(r2, id)
    #expect(rem.createCalls == 0)
    let snap9 = await r2.snapshot(id)!
    #expect(snap9.sideEffects["\(id)/c1"]?.status == .outcomeUnknown)
}

func makeRunnerSharing(store: any RunStore, reminders: FakeReminders, steps: [ScriptedModelProvider.Step]) -> (AgentRunner, ScriptedModelProvider, FakeReminders) {
    makeRunner(steps, store: store, reminders: reminders)
}

@Test func eventLogReplaysInOrderAndRejectsStaleOrDuplicateIngest() async throws {
    let store = InMemoryRunStore()
    let (r, _, _) = makeRunner([text("你好")], store: store)
    let id = try await r.start(conversationId: UUID(), text: "hi")
    await settle(r, id)
    let events = await store.events(runId: id, after: 0)
    #expect(events.map(\.sequence) == Array(1...events.count))
    let ing10 = await r.bus.ingest(events[0])
    #expect(ing10 == false)                 // duplicate
    var stale = events.last!; stale.sequence = 1
    let ing11 = await r.bus.ingest(stale)
    #expect(ing11 == false)                     // stale
    var fresh = events.last!; fresh = AgentEvent(eventId: UUID(), runId: id, conversationId: fresh.conversationId, stepId: "x", parentId: nil, sequence: events.count + 1, timestamp: .now, type: .runState, visibility: .activity, payload: .message("m"))
    let ing12 = await r.bus.ingest(fresh)
    #expect(ing12)
    // Public activity log carries no conversation content.
    let log = events.map { $0.redacted() }
    #expect(!String(data: try AgentCoding.encoder().encode(log), encoding: .utf8)!.contains("你好"))
}

@Test func sanitizerRemovesMarkupButKeepsChinese() {
    #expect(TextSanitizer.plain("所以，$12 \\times (3 + 4)$ 等于 **84**。") == "所以，12 × (3 + 4) 等于 84。")
    #expect(TextSanitizer.plain("## 标题\n- 一\n- 二") == "标题\n一\n二")
    #expect(TextSanitizer.plain("你好，世界。") == "你好，世界。")
}

@Test func everyModelSeesTheWholeCatalogButNoToolSchemasUpFront() async throws {
    for autonomy in [AutonomyLevel.chatOnly, .restrictedTools, .fullAgent] {
        let (r, p, _) = makeRunner([text("好")], autonomy: autonomy)
        let id = try await r.start(conversationId: UUID(), text: "你好")
        await settle(r, id)
        let req = p.requests[0]
        #expect(Set(req.tools.map(\.name)) == ["read_skill", "load_skill"], "discovery tools only; no forced-choice form is ever offered")
        let load = req.tools.first { $0.name == "load_skill" }!
        #expect(load.parameters["id"]?.enumValues?.contains("reminders") == true && load.description.contains("reminders=创建提醒"), "the whole catalog travels inside load_skill")
        let system = req.messages.first!.text
        #expect(system.contains("当前时间："))
        #expect(system.contains("工具失败时先读错误") && system.contains("技能已加载时不要重复加载"))
    }
}

@Test func readSkillNeedsNoPermissionAndShowsSchemasAndLiveStatus() async throws {
    let auth = StaticPermissionAuthority(system: [.reminders: .denied])
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "read_skill", .object(["id": .string("reminders")])), text("好")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([CreateReminderTool(store: FakeReminders())]), store: InMemoryRunStore(), permissions: auth)
    let id = try await r.start(conversationId: UUID(), text: "你会做什么")
    await settle(r, id)
    let result = p.requests[1].messages.last!.text
    #expect(result.contains("create_reminder") && result.contains("title: string"))
    #expect(result.contains("设置 › iTalk › 提醒事项"), "status shown, nothing requested")
    #expect(!p.requests[1].tools.contains { $0.name == "create_reminder" }, "read does not load")
}

@Test func toolFromUnloadedSkillLoadsItImplicitly() async throws {
    let (r, p, _) = makeRunner([call("c1", "calculate", .object(["expression": .string("6*7")])), text("42")])
    let id = try await r.start(conversationId: UUID(), text: "6乘7")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.loadedSkills == ["core"] && s.state == .completed)
    #expect(p.requests[1].messages.contains { $0.role == .tool && $0.text.contains("42") })
    #expect(p.requests[1].tools.contains { $0.name == "calculate" })
}

@Test func deniedPermissionReturnsRecoveryInsteadOfRunning() async throws {
    let rem = FakeReminders()
    let auth = StaticPermissionAuthority(system: [.reminders: .denied])
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "create_reminder", .object(["title": .string("喝水")])), text("需要权限")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([CreateReminderTool(store: rem)]), store: InMemoryRunStore(), permissions: auth)
    let id = try await r.start(conversationId: UUID(), text: "提醒我喝水")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(rem.createCalls == 0 && s.state == .completed && s.pending == nil, "no approval card for something that cannot run")
    guard case .permissionRecovery(let perm, _, let msg, let recovery)? = s.components.values.first?.component.content else { Issue.record("no card"); return }
    #expect(perm == .reminders && recovery == .openSystemSettings && msg.contains("设置"))
    #expect(p.requests[1].messages.last!.text.contains("permission_unavailable"))
    // iTalk switch off: recovery points inside iTalk.
    let off = StaticPermissionAuthority(enabled: Set(Capability.allCases).subtracting([.reminders]))
    let v = await PermissionGate.evaluate(CreateReminderTool(store: rem).spec, authority: off)
    #expect(!v.allowed && v.recovery == .enableInITalk)
    // Not yet asked: the system prompt is requested, then it runs.
    let ask = StaticPermissionAuthority(system: [.reminders: .notDetermined], afterPrompt: .granted)
    let v2 = await PermissionGate.evaluate(CreateReminderTool(store: rem).spec, authority: ask)
    #expect(v2.allowed)
    let v3 = await PermissionGate.evaluate(CreateReminderTool(store: rem).spec, authority: ask, mayRequest: false)
    #expect(!v3.allowed, "background/read paths never trigger a prompt")
}

@Test func sameSideEffectIsNotRepeatedAcrossRunsOrModels() async throws {
    let rem = FakeReminders()
    let journal = ExecutionJournal()
    let store = InMemoryRunStore()
    let conv = UUID()
    let args: JSONValue = .object(["title": .string("吃药")])
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "create_reminder", args), text("好了"), call("c9", "create_reminder", args), text("已经有了")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([CreateReminderTool(store: rem)]), store: store, permissions: StaticPermissionAuthority(), journal: journal)
    let id = try await r.start(conversationId: conv, text: "提醒我吃药")
    await settle(r, id)
    let c = (await r.snapshot(id)!).components.values.first!.component
    try await r.submit(UIActionResponse(runId: id, componentId: c.id, componentRevision: 1, actionId: "approve", idempotencyKey: "k"))
    await settle(r, id)
    #expect(rem.createCalls == 1)
    // A different model (after a switch) asks for the identical action in a new run of the same conversation.
    await r.use(ScriptedModelProvider(descriptor: .scripted(id: "other"), steps: []))
    await r.use(p)
    let id2 = try await r.start(conversationId: conv, text: "再提醒我吃药")
    await settle(r, id2)
    let s2 = await r.snapshot(id2)!
    #expect(rem.createCalls == 1 && s2.state == .completed && s2.pending == nil)
    #expect(s2.messages.contains { $0.role == .tool && $0.text.contains("吃药") })
    let history = await journal.history(conversationId: conv)
    #expect(history.count == 1 && history[0].status == .completed)
}

final class SlowSideEffect: AgentTool, @unchecked Sendable {
    let spec = ToolSpec(name: "slow_action", description: "慢操作", permission: .lowRiskAction, capability: .device)
    private let lock = NSLock(); private var _done = 0
    var done: Int { lock.withLock { _done } }
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try? await Task.sleep(for: .milliseconds(150))       // ignores cancellation like a real system call in flight
        lock.withLock { _done += 1 }
        return ToolOutput(value: .object(["ok": .bool(true)]), summary: "完成")
    }
}

@Test func cancellingTheRunNeverAbortsASideEffectHalfway() async throws {
    let tool = SlowSideEffect()
    let journal = ExecutionJournal()
    var catalog = SkillCatalog.standard; catalog.add(Skill(id: "dev", name: "设备", summary: "测试", instructions: "", toolNames: ["slow_action"]))
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "slow_action", .object([:])), text("好")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([tool]), skills: catalog, store: InMemoryRunStore(), permissions: StaticPermissionAuthority(), journal: journal)
    let conv = UUID()
    let id = try await r.start(conversationId: conv, text: "做")
    try await Task.sleep(for: .milliseconds(60))
    await r.cancel(id)                                     // e.g. the user barged in while the action was running
    try await Task.sleep(for: .milliseconds(300))
    #expect(tool.done == 1)
    let rec = await journal.history(conversationId: conv).first
    #expect(rec?.status == .completed, "result journaled even though the run was cancelled")
}

@Test func personalToolResultsAreWithheldFromCloudModelsUnlessAllowed() async throws {
    let cloud = ModelDescriptor(id: "cloud", kind: .cloudGateway, displayName: "cloud", capabilities: ProviderCapabilities(contextWindow: 8000, toolCalling: .native, structuredOutput: true, maxAutonomy: .fullAgent, worksOffline: false, sendsContentOffDevice: true))
    for allowed in [false, true] {
        let enabled = allowed ? Set(Capability.allCases) : Set(Capability.allCases).subtracting([.cloudPersonalData])
        let p = ScriptedModelProvider(descriptor: cloud, steps: [call("c1", "list_test", .object([:])), text("好")])
        var catalog = SkillCatalog.standard; catalog.add(Skill(id: "t", name: "t", summary: "t", instructions: "", toolNames: ["list_test"]))
        let r = AgentRunner(provider: p, tools: ToolRegistry([PersonalReadTool()]), skills: catalog, store: InMemoryRunStore(), permissions: StaticPermissionAuthority(enabled: enabled))
        let id = try await r.start(conversationId: UUID(), text: "看看")
        await settle(r, id)
        let tool = p.requests[1].messages.last { $0.role == .tool }!
        #expect(tool.text.contains("王小明") == allowed)
        let local = await r.snapshot(id)!.messages.last { $0.role == .tool }!
        #expect(local.text.contains("王小明"), "the run itself keeps the real result on the device")
    }
}

struct PersonalReadTool: AgentTool {
    let spec = ToolSpec(name: "list_test", description: "个人数据", permission: .readOnly, capability: .contacts, systemPermission: .contacts, dataClass: .personal)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput { ToolOutput(value: .object(["name": .string("王小明")]), summary: "1 人") }
}

@Test func voiceTurnsAskForSpokenStyle() async throws {
    let (r, p, _) = makeRunner([text("好呀。")])
    let id = try await r.start(conversationId: UUID(), text: "今天心情不错", source: "voice")
    await settle(r, id)
    #expect(p.requests[0].messages.first?.text.contains("语音对话") == true)
}

@Test func backgroundSuspendParksTheRunAndResumeFinishesIt() async throws {
    let slow = ScriptedModelProvider.Step((0..<40).map { .textDelta("字\($0)") } + [.completed(.stop)], delayMs: 15)
    let (r, p, _) = makeRunner([slow, text("完整回答")])
    let id = try await r.start(conversationId: UUID(), text: "讲讲", tag: "turn-1")
    try await Task.sleep(for: .milliseconds(100))
    await r.suspend(id)
    var s = await r.snapshot(id)!
    #expect(s.state == .awaitingForeground && s.finalText == nil && s.tag == "turn-1")
    await r.resume(id)
    await settle(r, id)
    s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "完整回答" && p.requests.count == 2, "the interrupted step is regenerated, not lost")
    let active = await r.activeRuns()
    #expect(active.isEmpty)
}

@Test func runsInDifferentConversationsProceedIndependently() async throws {
    let (r, _, _) = makeRunner([text("一"), text("二")])
    let a = try await r.start(conversationId: UUID(), text: "A"), b = try await r.start(conversationId: UUID(), text: "B")
    await settle(r, a); await settle(r, b)
    let sa = await r.snapshot(a)!, sb = await r.snapshot(b)!
    #expect(sa.state == .completed && sb.state == .completed && Set([sa.finalText, sb.finalText]) == ["一", "二"])
}


@Test func fabricatedCompletionWithoutAnyToolIsDiscardedAndCorrected() async throws {
    // Seen on device: the model answered "已成功设置闹钟" with zero tool calls.
    let (r, p, _) = makeRunner([text("已成功设置闹钟：今天 10:00。"), call("c1", "load_skill", .object(["id": .string("reminders")])),
                                call("c2", "create_reminder", .object(["title": .string("10点闹钟")])), text("已创建提醒。")])
    let id = try await r.start(conversationId: UUID(), text: "设一个10点的提醒")
    await settle(r, id)
    var s = await r.snapshot(id)!
    #expect(s.state == .awaitingApproval, "after the correction the model really acts, and the action asks first")
    #expect(s.nudges == 1 && p.requests.count == 3)
    #expect(p.requests[1].messages.contains { $0.role == .user && $0.text.contains("没有调用任何工具") })
    #expect(!p.requests[1].messages.contains { $0.role == .assistant && $0.text.contains("已成功") }, "the false claim is not kept as context")
    s = await r.snapshot(id)!
    #expect(!s.messages.contains { $0.role == .assistant && $0.text.contains("已成功设置") })
}

@Test func honestAnswersAreNotNudged() async throws {
    let (r, p, _) = makeRunner([text("我没有执行任何操作；需要的话可以让我设置。")])
    let id = try await r.start(conversationId: UUID(), text: "你能设闹钟吗")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.nudges == nil && p.requests.count == 1)
    #expect(ActionClaims.claimsCompletion("已为你创建了日程") && ActionClaims.claimsCompletion("提醒设置好了") && !ActionClaims.claimsCompletion("我可以帮你设置闹钟"))
}

@Test func toolStepsAreEmittedProgressivelyWithResultsAndFailures() async throws {
    let (r, _, _) = makeRunner([call("c1", "load_skill", .object(["id": .string("core")])), call("c2", "calculate", .object(["expression": .string("6*7")])),
                                call("c3", "calculate", .object(["expression": .string("1/0")])), text("好")])
    let stream = await r.bus.subscribe()
    let id = try await r.start(conversationId: UUID(), text: "算")
    await settle(r, id)
    var acts: [ToolActivity] = []
    for await e in stream { if case .activity(let a) = e.payload { acts.append(a) }; if e.type == .runCompleted { break } }
    #expect(acts.first { $0.kind == .skill }?.title == "已加载技能：时间与计算")
    #expect(acts.filter { $0.callId == "c2" }.map(\.state) == [.running, .succeeded])
    #expect(acts.first { $0.callId == "c2" && $0.state == .succeeded }?.summary.contains("42") == true)
    #expect(acts.first { $0.callId == "c3" && $0.state == .failed }?.summary.contains("无法计算") == true, "failures are visible with a reason")
}

struct ThrowingTool: AgentTool {
    let spec = ToolSpec(name: "boom", description: "会失败的工具", permission: .readOnly, capability: .device)
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput { throw NSError(domain: "AlarmKit.AlarmManager.AlarmError", code: 1, userInfo: [NSLocalizedDescriptionKey: "maximum alarms reached"]) }
}

@Test func unexpectedErrorsKeepTheirReason() async throws {
    var cat = SkillCatalog.standard; cat.add(Skill(id: "dev", name: "设备", summary: "测试", instructions: "", toolNames: ["boom"]))
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "boom", .object([:])), text("失败了")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([ThrowingTool()]), skills: cat, store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
    let id = try await r.start(conversationId: UUID(), text: "试")
    await settle(r, id)
    let tool = (await r.snapshot(id)!).messages.first { $0.role == .tool }!
    #expect(tool.text.contains("maximum alarms reached") && tool.text.contains("AlarmError"))
}

@Test func reasoningParserSplitsAcrossChunksAndNeverLeaksIntoTheAnswer() {
    // Thinking mode: the block is opened by the prompt, so output starts inside it.
    var p = ReasoningTextParser(startsInside: true)
    var r = "", t = ""
    for c in ["先看日", "程。</thi", "nk>\n\n明天", "有两个会。"] { let o = p.feed(c); r += o.reasoning; t += o.text }
    let f = p.finish(); r += f.reasoning; t += f.text
    #expect(r == "先看日程。" && t == "明天有两个会。")
    // Tags written out in full, mid-stream, and stray tags when thinking is off.
    var q = ReasoningTextParser()
    var qr = "", qt = ""
    for c in ["好的<think>用户想", "设闹钟</think>已设置"] { let o = q.feed(c); qr += o.reasoning; qt += o.text }
    #expect(qr == "用户想设闹钟" && qt == "好的已设置")
    // A truncated thought (token limit) stays reasoning; it is never promoted to an answer.
    var s = ReasoningTextParser(startsInside: true)
    let a = s.feed("还没想完"), b = s.finish()
    #expect(a.text.isEmpty && b.text.isEmpty && a.reasoning + b.reasoning == "还没想完")
}

@Test func runnerStreamsPersistsAndSeparatesRealReasoning() async throws {
    let step = ScriptedModelProvider.Step([.reasoningDelta("用户要算乘法，"), .reasoningDelta("调用计算器。"), .toolCall(ToolCall(id: "c1", name: "calculate", arguments: .object(["expression": .string("6*7")]))), .completed(.toolCalls)])
    let (r, p, _) = makeRunner([step, .init([.reasoningDelta("结果是42。"), .textDelta("答案是42。"), .completed(.stop)])])
    await r.setReasoning(true)
    let stream = await r.bus.subscribe()
    let id = try await r.start(conversationId: UUID(), text: "6乘7")
    await settle(r, id)
    var thoughts: [String] = []
    for await e in stream { if e.type == .reasoningDelta, case .textDelta(let d) = e.payload { thoughts.append(d) }; if e.type == .runCompleted { break } }
    #expect(thoughts == ["用户要算乘法，", "调用计算器。", "结果是42。"])
    let s = await r.snapshot(id)!
    #expect(s.reasoning?.map(\.text) == ["用户要算乘法，调用计算器。", "结果是42。"] && s.finalText == "答案是42。")
    #expect(p.requests[0].reasoning && p.requests[0].maxTokens == 2048, "thinking gets a larger token allowance")
    #expect(!s.messages.contains { $0.text.contains("用户要算乘法") }, "reasoning is never fed back to the model as context")
    // A model that provides no reasoning produces none: nothing is fabricated.
    let (r2, _, _) = makeRunner([text("你好")])
    let id2 = try await r2.start(conversationId: UUID(), text: "嗨")
    await settle(r2, id2)
    #expect((await r2.snapshot(id2)!).reasoning == nil)
}

@Test func spokenTurnsNeverAskForReasoning() async throws {
    let (r, p, _) = makeRunner([text("好")])
    await r.setReasoning(true)
    let id = try await r.start(conversationId: UUID(), text: "嗨", source: "voice")
    await settle(r, id)
    #expect(p.requests[0].reasoning == false)
}

@Test func toolLoopIsBrokenByWithholdingToolsSoTheModelMustAnswer() async throws {
    // Seen with the 2B model: the same search again and again until the step budget failed the whole task.
    let same = call("x", "calculate", .object(["expression": .string("1+1")]))
    var steps = (1...3).map { i in ScriptedModelProvider.Step([.toolCall(ToolCall(id: "c\(i)", name: "calculate", arguments: .object(["expression": .string("1+1")]))), .completed(.toolCalls)]) }
    steps.append(text("结果是2。")); _ = same
    let (r, p, _) = makeRunner(steps)
    let id = try await r.start(conversationId: UUID(), text: "算一下")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "结果是2。" && s.forceAnswer == true)
    #expect(p.requests.last!.tools.isEmpty, "the last step is asked without tools")
    #expect(p.requests.last!.messages.first!.text.contains("现在不能再调用任何工具"))
}

@Test func runningLowOnStepsSpendsThemOnAnAnswerInsteadOfFailing() async throws {
    let looping = (0..<10).map { i in ScriptedModelProvider.Step([.toolCall(ToolCall(id: "c\(i)", name: "calculate", arguments: .object(["expression": .string("\(i)+1")]))), .completed(.toolCalls)]) } + [text("已有结果如上。")]
    let (r, _, _) = makeRunner(looping)
    let id = try await r.start(conversationId: UUID(), text: "loop")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "已有结果如上。", "got \(s.state) \(s.failure ?? "")")
}

@Test func disabledSkillsAreInvisibleAndTheirToolsRefuseToRun() async throws {
    let rem = FakeReminders()
    let p = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "load_skill", .object(["id": .string("reminders")])),
        call("c2", "create_reminder", .object(["title": .string("x")])), text("好")])
    let r = AgentRunner(provider: p, tools: ToolRegistry([CreateReminderTool(store: rem)]), store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
    await r.setDisabledSkills(["reminders"])
    let id = try await r.start(conversationId: UUID(), text: "提醒我x")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(rem.createCalls == 0 && s.state == .completed)
    let load = p.requests[0].tools.first { $0.name == "load_skill" }!
    #expect(load.parameters["id"]?.enumValues?.contains("reminders") == false, "a disabled skill is not in the catalog the model sees")
    #expect(s.messages.contains { $0.role == .tool && ($0.text.contains("没有这个技能") || $0.text.contains("已被用户关闭")) })
    // Naming the tool directly does not bypass the switch.
    let p2 = ScriptedModelProvider(descriptor: .scripted(), steps: [call("c1", "create_reminder", .object(["title": .string("x")])), text("好")])
    let r2 = AgentRunner(provider: p2, tools: ToolRegistry([CreateReminderTool(store: rem)]), store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
    await r2.setDisabledSkills(["reminders"])
    let id2 = try await r2.start(conversationId: UUID(), text: "提醒我x")
    await settle(r2, id2)
    let s2 = await r2.snapshot(id2)!
    #expect(rem.createCalls == 0 && s2.pending == nil && s2.messages.contains { $0.role == .tool && $0.text.contains("已被用户关闭") })
}
