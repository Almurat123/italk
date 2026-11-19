import Foundation
import Testing
@testable import AgentRuntime

// The real runner, a scripted model and the reducer fed from the live bus: the shapes the reducer relies on are the shapes the
// runner really emits.

private func steps(_ deltas: [String]) -> ScriptedModelProvider.Step {
    .init(deltas.map { GenerationEvent.textDelta($0) } + [.usage(Usage(promptTokens: 10, completionTokens: 5, providerId: "scripted")), .completed(.stop)])
}

private let registry = ToolRegistry([DateTimeTool(), CalculatorTool(), CreateReminderTool(store: FakeReminders())])

private func operation(_ name: String) -> CompanionOperation? {
    registry.tool(named: name).map { CompanionOperation.of($0.spec.capability, hasSideEffect: $0.spec.hasSideEffect) }
}

/// Applies every bus event to a reducer, as the app's hub does.
private final class Feeder: @unchecked Sendable {
    private let lock = NSLock()
    private var reducer: CompanionReducer
    private var all: [CompanionCue] = []
    private var types: [AgentEventType] = []
    private var pump: Task<Void, Never>?

    init(_ stream: AsyncStream<AgentEvent>) {
        var config = CompanionReducer.Config()
        config.operation = operation
        reducer = CompanionReducer(config: config)
        pump = Task { [weak self] in for await e in stream { self?.apply(e) } }
    }
    private func apply(_ e: AgentEvent) {
        lock.withLock { types.append(e.type); all += reducer.apply(.agent(e, turn: nil, origin: .localAgent)) }
    }
    var cues: [CompanionCue] { lock.withLock { all } }
    var cue: CompanionCue { lock.withLock { reducer.cue } }
    var seen: [AgentEventType] { lock.withLock { types } }
    func stop() { pump?.cancel() }

    /// Waits (bounded) until `condition` holds.
    func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<300 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}

@Test func toneTagsNeverReachTheTextTheEventsOrTheStore() async throws {
    let store = InMemoryRunStore()
    let (r, _, _) = makeRunner([steps(["[to", "ne:comf", "orting:high] 别担心，", "没事的。[tone:encouraging]一起来。"])], store: store)
    let stream = await r.bus.subscribe()
    let id = try await r.start(conversationId: UUID(), text: "我有点难过")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed && s.finalText == "别担心，没事的。一起来。")
    #expect(s.messages.last?.text == "别担心，没事的。一起来。", "the model's stored message is clean too")

    let stored = await store.events(runId: id, after: 0)
    #expect(!stored.contains { $0.type == .companionSegment }, "expression metadata is transient: never stored")
    #expect(!stored.contains { if case .textDelta(let d) = $0.payload { d.contains("[") || d.contains("tone") } else { false } })

    var live: [AgentEvent] = []
    for await e in stream { live.append(e); if e.type == .runCompleted { break } }
    let segments = live.filter { $0.type == .companionSegment }
    #expect(segments.count == 2)
    guard segments.count == 2, case .segment(let a) = segments[0].payload, case .segment(let b) = segments[1].payload else { Issue.record("segment payloads"); return }
    #expect(a.index == 0 && a.label == "comforting" && a.offset == 0 && a.intensity == 0.9)
    #expect(b.index == 1 && b.label == "encouraging" && b.offset == "别担心，没事的。".utf16.count && b.intensity == nil)
    let ordered = live.filter { $0.type == .modelDelta || $0.type == .companionSegment }
    #expect(ordered.first?.type == .companionSegment, "the segment is announced before its first text")
    let sequences = live.map(\.sequence)
    #expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count)
}

@Test func theToneInstructionIsSentOnlyWhenEnabledAndStrippingAlwaysHappens() async throws {
    let (on, pOn, _) = makeRunner([text("好的。")])
    let a = try await on.start(conversationId: UUID(), text: "你好")
    await settle(on, a)
    let system = pOn.requests.first?.messages.first?.text ?? ""
    #expect(system.contains("[tone:xxx]") && system.contains("不是用户的心情"))

    var config = RunnerConfig(); config.semanticCues = false
    let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [steps(["[tone:celebrating]搞定！"])])
    let off = AgentRunner(provider: provider, tools: registry, store: InMemoryRunStore(), granted: { allCaps }, config: config)
    let stream = await off.bus.subscribe()
    let b = try await off.start(conversationId: UUID(), text: "你好")
    await settle(off, b)
    let offSystem = provider.requests.first?.messages.first?.text ?? ""
    var context = ""
    if let hit = offSystem.range(of: "tone:") {
        let start = offSystem.index(hit.lowerBound, offsetBy: -30, limitedBy: offSystem.startIndex) ?? offSystem.startIndex
        context = String(offSystem[start..<hit.upperBound])
    }
    #expect(!offSystem.contains("[tone:") && !offSystem.contains("语气标注"), "found: \(context)")
    let s = await off.snapshot(b)!
    #expect(s.finalText == "搞定！", "a tag a model writes anyway is still removed")
    var segmentEvents = 0
    for await e in stream { if e.type == .companionSegment { segmentEvents += 1 }; if e.type == .runCompleted { break } }
    #expect(segmentEvents == 0)
}

@Test func aGuidedSmallModelDoesNotSeeTheToneInstructionWhileItChoosesATool() async throws {
    var catalog = SkillCatalog.standard
    catalog.add(Skill(id: "reminders", name: "提醒事项", summary: "创建提醒事项", instructions: "", toolNames: ["create_reminder"]))
    var config = RunnerConfig(); config.skillSelectionOverride = .guided
    let reminders = FakeReminders()
    // 1: the selector answers · 2: the step that calls the tool · 3: the answer after the tool result
    let provider = ScriptedModelProvider(descriptor: .scripted(), steps: [text("reminders"), call("c1", "create_reminder", .object(["title": .string("喝水")])), text("好了")])
    let runner = AgentRunner(provider: provider, tools: ToolRegistry([CreateReminderTool(store: reminders)]), skills: catalog, store: InMemoryRunStore(),
                             permissions: StaticPermissionAuthority(), config: config)
    let id = try await runner.start(conversationId: UUID(), text: "提醒我喝水")
    await settle(runner, id)
    let s = await runner.snapshot(id)!, card = s.components[s.pending!.componentId]!.component
    try await runner.submit(UIActionResponse(runId: id, componentId: card.id, componentRevision: card.revision, actionId: "approve", idempotencyKey: "k"))
    await settle(runner, id)
    func system(_ index: Int) -> String { provider.requests[index].messages.first?.text ?? "" }
    #expect(provider.requests.count == 3)
    #expect(!system(1).contains("[tone:xxx]"), "the step that must pick the tool is not given anything else to think about")
    #expect(system(2).contains("[tone:xxx]"), "the answer after the tool result may carry a tone")

    // No tool needed (the selector chose nothing): the answer step gets it at once.
    let chat = ScriptedModelProvider(descriptor: .scripted(), steps: [text("无"), text("你好！")])
    let r2 = AgentRunner(provider: chat, tools: ToolRegistry([CreateReminderTool(store: FakeReminders())]), skills: catalog, store: InMemoryRunStore(),
                         permissions: StaticPermissionAuthority(), config: config)
    let b = try await r2.start(conversationId: UUID(), text: "你好")
    await settle(r2, b)
    #expect(chat.requests.count == 2 && (chat.requests[1].messages.first?.text ?? "").contains("[tone:xxx]"))
}

@Test func anUnfinishedOrUnknownTagLeavesNoTraceAndNoCrash() async throws {
    let (r, _, _) = makeRunner([steps(["[tone:banana]你好，[tone:cautio"])])
    let id = try await r.start(conversationId: UUID(), text: "你好")
    await settle(r, id)
    let s = await r.snapshot(id)!
    #expect(s.state == .completed)
    #expect(s.finalText == "你好，[tone:cautio", "an unfinished tag is text, an unknown complete one is removed")
}

@Test func aSuccessfulToolRunEndsWithACelebrationTheReducerAllows() async throws {
    let (r, _, _) = makeRunner([call("c1", "calculate", .object(["expression": .string("12*(3+4)")])), steps(["[tone:celebrating:high]算好了，", "是84！"])])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "十二乘七加四")
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    let cues = feeder.cues
    #expect(cues.contains { $0.phase == .working && $0.operation == .compute })
    #expect(cues.contains { $0.event == .toolSucceeded })
    #expect(!cues.contains { $0.intent == .celebrating && $0.phase != .completed }, "never celebrates before the run has succeeded")
    #expect(feeder.cue.intent == .celebrating && feeder.cue.intensity == 0.9 && feeder.cue.intentSource == .model)
    #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    _ = id
    feeder.stop()
}

@Test func theRunnerStampsEachToolStepWithItsOperationFromTheToolSpec() async throws {
    let store = InMemoryRunStore()
    let (r, _, _) = makeRunner([call("c1", "calculate", .object(["expression": .string("2+2")])), text("四。")], store: store)
    let id = try await r.start(conversationId: UUID(), text: "二加二")
    await settle(r, id)
    let activities = await store.events(runId: id, after: 0).compactMap { e -> ToolActivity? in if case .activity(let a) = e.payload { a } else { nil } }
    #expect(!activities.isEmpty && activities.allSatisfy { $0.operation == .compute })
    // An activity recorded before the field existed still decodes.
    let old = try JSONEncoder().encode(ToolActivity(callId: "x", name: "n", kind: .tool, state: .running, title: "t", detail: "", summary: "", facts: [],
                                                    sources: [], recovery: .none, permission: nil, symbol: "gearshape"))
    var object = try JSONSerialization.jsonObject(with: old) as! [String: Any]
    object["operation"] = nil
    let decoded = try JSONDecoder().decode(ToolActivity.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.operation == nil)
}

@Test func aFailedToolRunNeverCelebratesWhateverTheModelDeclares() async throws {
    let (r, _, _) = makeRunner([call("c1", "calculate", .object(["expression": .string("不是算式")])), steps(["[tone:celebrating]搞定！"])])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "算一下")
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    #expect(feeder.cues.contains { $0.event == .toolFailed })
    #expect(!feeder.cues.contains { $0.intent == .celebrating })
    #expect(feeder.cue.intent == .neutral)
    _ = id
    feeder.stop()
}

@Test func aRealRunWaitingForApprovalNeverLooksLikeWork() async throws {
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("喝水")])), steps(["[tone:celebrating]已创建提醒！"])])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "提醒我喝水")
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .awaitingApproval })
    #expect(feeder.cue.operation == nil && rem.createCalls == 0)
    #expect(!feeder.cues.contains { $0.phase == .working }, "nothing executed yet")

    let s = await r.snapshot(id)!
    let component = s.components[s.pending!.componentId]!.component
    try await r.submit(UIActionResponse(runId: id, componentId: component.id, componentRevision: component.revision, actionId: "approve", idempotencyKey: "k1"))
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    let cues = feeder.cues
    let waiting = cues.firstIndex { $0.phase == .awaitingApproval }, working = cues.firstIndex { $0.phase == .working }
    #expect(waiting != nil && working != nil && waiting! < working!)
    #expect(cues.contains { $0.phase == .working && $0.operation == .write })
    #expect(cues.contains { $0.event == .approvalResolved && $0.detail == "approved" })
    #expect(feeder.cue.intent == .celebrating)
    feeder.stop()
}

@Test func aDeclinedRealApprovalNeverWorksAndNeverCelebrates() async throws {
    let (r, _, rem) = makeRunner([call("c1", "create_reminder", .object(["title": .string("x")])), steps(["[tone:celebrating]好的！"])])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "提醒我x")
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .awaitingApproval })
    let s = await r.snapshot(id)!, c = s.components[s.pending!.componentId]!.component
    try await r.submit(UIActionResponse(runId: id, componentId: c.id, componentRevision: 1, actionId: "decline", idempotencyKey: "k", authorization: .none))
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    #expect(rem.createCalls == 0)
    #expect(!feeder.cues.contains { $0.phase == .working })
    #expect(feeder.cues.contains { $0.event == .approvalResolved && $0.detail == "declined" })
    #expect(feeder.cue.intent == .neutral, "the action was declined: no celebration")
    feeder.stop()
}

@Test func cancellingARunEndsItOnceAndSilencesLateEvents() async throws {
    let slow = ScriptedModelProvider.Step([.textDelta("正在"), .textDelta("回答"), .completed(.stop)], delayMs: 80)
    let (r, _, _) = makeRunner([slow])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "你好")
    #expect(await feeder.eventually { feeder.cue.phase == .thinking })
    await r.cancel(id)
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .cancelled })
    let count = feeder.cues.count
    try await Task.sleep(for: .milliseconds(250))
    #expect(feeder.cues.count == count, "nothing acts after the cancellation")
    #expect(feeder.cues.filter { $0.event == .cancelled }.count == 1)
    feeder.stop()
}

@Test func aDroppedNetworkIsShownAndTheResumedRunCompletesOnce() async throws {
    // The first generation streams a little text and loses the network; the run parks and, once resumed, regenerates the same step.
    let (r, _, _) = makeRunner([ScriptedModelProvider.Step([.textDelta("正在")], error: .network), steps(["[tone:encouraging]好了，继续。"])])
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "你好")
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.connectivity == .reconnecting })
    #expect(feeder.cue.phase == .thinking && feeder.cue.event == .reconnecting)
    await r.resume(id)
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    #expect(feeder.cues.contains { $0.event == .resumed } && feeder.cue.connectivity == .live)
    #expect(feeder.cues.filter { $0.event == .completed }.count == 1)
    #expect(feeder.cue.intent == .encouraging, "the regenerated step's own declaration applies, not the interrupted one's text")
    feeder.stop()
}

@Test func switchingTheModelBetweenStepsIsSeenByTheReducer() async throws {
    // The first step is slow and ends with a tool call; the person switches model while it runs, so the next step is the new model's.
    let firstStep = ScriptedModelProvider.Step([.toolCall(ToolCall(id: "c1", name: "calculate", arguments: .object(["expression": .string("1+1")]))),
                                                .completed(.toolCalls)], delayMs: 60)
    let a = ScriptedModelProvider(descriptor: .scripted(id: "local-2b"), steps: [firstStep])
    let r = AgentRunner(provider: a, tools: registry, store: InMemoryRunStore(), granted: { allCaps })
    let feeder = Feeder(await r.bus.subscribe())
    let id = try await r.start(conversationId: UUID(), text: "一加一")
    try await Task.sleep(for: .milliseconds(20))
    await r.use(ScriptedModelProvider(descriptor: .scripted(id: "iTalk-cloud"), steps: [steps(["[tone:explaining]等于二。"])]))
    await settle(r, id)
    #expect(await feeder.eventually { feeder.cue.phase == .completed })
    #expect(feeder.cues.contains { $0.providerId == "local-2b" })
    #expect(feeder.cues.contains { $0.event == .modelSwitched && $0.detail == "iTalk-cloud" && $0.providerId == "iTalk-cloud" })
    #expect(feeder.cue.providerId == "iTalk-cloud" && feeder.cue.intent == .explaining)
    feeder.stop()
}
