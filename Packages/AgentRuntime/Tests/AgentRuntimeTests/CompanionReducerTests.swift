import Foundation
import Testing
@testable import AgentRuntime

// MARK: - Rig

private func toolOperation(_ name: String) -> CompanionOperation? {
    switch name {
    case "send_message": return .communicate
    case "web_search": return .lookup
    case "create_event": return .write
    default: return nil
    }
}

private struct Rig {
    var reducer: CompanionReducer
    var cues: [CompanionCue] = []
    var clock = Date(timeIntervalSince1970: 10_000)
    var conv = UUID()
    var run = UUID()
    var seq = 0
    var turn = UUID()

    init() {
        var config = CompanionReducer.Config()
        config.operation = toolOperation
        reducer = CompanionReducer(config: config, now: Date(timeIntervalSince1970: 10_000))
    }

    var cue: CompanionCue { reducer.cue }

    mutating func tick(_ dt: Double = 0.05) -> Date { clock = clock.addingTimeInterval(dt); return clock }

    @discardableResult
    mutating func agent(_ type: AgentEventType, _ payload: EventPayload, step: String = "model-1", turn t: UUID? = nil,
                        origin: CompanionOrigin = .localAgent, run override: UUID? = nil, conversation: UUID? = nil,
                        taskId: String? = nil, sequence: Int? = nil) -> [CompanionCue] {
        seq = sequence ?? seq + 1
        let e = AgentEvent(eventId: UUID(), runId: override ?? run, conversationId: conversation ?? conv, stepId: step, parentId: nil,
                           sequence: seq, timestamp: clock, type: type, visibility: .activity, payload: payload)
        let out = reducer.apply(.agent(e, turn: t, origin: origin, taskId: taskId), at: tick())
        cues += out
        return out
    }

    @discardableResult
    mutating func voice(_ s: CompanionVoiceSignal, dt: Double = 0.05) -> [CompanionCue] {
        let out = reducer.apply(.voice(s), at: tick(dt))
        cues += out
        return out
    }

    @discardableResult
    mutating func apply(_ input: CompanionInput) -> [CompanionCue] {
        let out = reducer.apply(input, at: tick())
        cues += out
        return out
    }

    mutating func startTextRun(provider: String = "cloud", turn t: UUID? = nil) {
        agent(.runCreated, .message("text"), turn: t)
        agent(.runState, state(.created, .running), turn: t)
        agent(.modelStarted, .modelRequest(providerId: provider, step: 1), turn: t)
    }

    /// A second model step that answers with `text`, optionally declaring a tone first.
    mutating func answer(_ text: String, tone: String? = nil, intensity: Double? = nil, step: Int = 2, turn t: UUID? = nil, provider: String = "cloud") {
        agent(.modelStarted, .modelRequest(providerId: provider, step: step), step: "model-\(step)", turn: t)
        if let tone { agent(.companionSegment, .segment(ToneSegment(index: 0, offset: 0, label: tone, intensity: intensity)), step: "model-\(step)", turn: t) }
        agent(.modelDelta, .textDelta(text), step: "model-\(step)", turn: t)
        agent(.modelCompleted, .modelFinished(providerId: provider, finish: .stop), step: "model-\(step)", turn: t)
    }

    mutating func toolRound(_ id: String, name: String = "create_event", ok: Bool, turn t: UUID? = nil) {
        agent(.toolStarted, .toolCall(callId: id, name: name), step: id, turn: t)
        if ok {
            agent(.toolCompleted, .toolSummary(callId: id, name: name, summary: "完成"), step: id, turn: t)
            agent(.toolProgress, activity(id, .succeeded, name: name), step: id, turn: t)
        } else {
            agent(.toolFailed, .toolError(callId: id, name: name, code: "failed"), step: id, turn: t)
            agent(.toolProgress, activity(id, .failed, name: name), step: id, turn: t)
        }
    }

    /// A spoken turn up to the first audio: listening → transcribing → thinking → (run) → synthesizing → speaking.
    mutating func spokenTurnSpeaking(runCompleted: Bool = true, tone: String? = nil, toolOK: Bool? = nil, text: String = "好的。") {
        voice(.micPreparing)
        voice(.phase(.preparing, turn: turn, conversation: conv, spoken: true))
        voice(.micLive)
        voice(.phase(.listening, turn: turn, conversation: conv, spoken: true))
        voice(.phase(.finalizing, turn: turn, conversation: conv, spoken: true))
        voice(.phase(.thinking, turn: turn, conversation: conv, spoken: true))
        startTextRun(turn: turn)
        if let toolOK { toolRound("c1", ok: toolOK, turn: turn) }
        answer(text, tone: tone, turn: turn)
        if runCompleted { agent(.runState, state(.running, .completed), turn: turn) }
        voice(.phase(.synthesizing, turn: turn, conversation: conv, spoken: true))
        voice(.phase(.speaking, turn: turn, conversation: conv, spoken: true))
    }
}

private func state(_ from: RunState, _ to: RunState, reason: String? = nil) -> EventPayload { .state(from: from, to: to, reason: reason) }

private func activity(_ id: String, _ s: ToolActivity.State, name: String = "send_message", kind: ToolActivity.Kind = .tool) -> EventPayload {
    .activity(ToolActivity(callId: id, name: name, kind: kind, state: s, title: name, detail: "", summary: "", facts: [], sources: [],
                           recovery: .none, permission: nil, symbol: "gearshape"))
}

private func approval(_ id: String, approved: Bool?) -> EventPayload { .approval(approvalId: "approval-\(id)", summary: "发送消息", approved: approved) }

private func strictlyIncreasing(_ cues: [CompanionCue]) -> Bool {
    zip(cues, cues.dropFirst()).allSatisfy { $0.sequence < $1.sequence }
}

// MARK: - Run lifecycle

@Test func aTextRunReportsOnlyWhatHappened() {
    var rig = Rig()
    #expect(rig.cue.phase == .idle)
    rig.startTextRun()
    #expect(rig.cue.phase == .thinking && !rig.cue.answering)
    #expect(rig.cue.origin == .localAgent && rig.cue.providerId == "cloud")
    rig.agent(.reasoningDelta, .textDelta("先想想"))
    #expect(!rig.cue.answering, "reasoning is not an answer and is never an input")
    rig.agent(.modelDelta, .textDelta("你好"))
    #expect(rig.cue.answering && rig.cue.phase == .thinking, "streaming text is silent: not speaking")
    rig.agent(.modelCompleted, .modelFinished(providerId: "cloud", finish: .stop))
    #expect(!rig.cue.answering)
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.phase == .completed && rig.cue.event == .completed)
    #expect(strictlyIncreasing(rig.cues))
    let before = rig.cues.count
    rig.agent(.runCompleted, .message("completed"))              // the runner reports completion twice
    rig.agent(.modelDelta, .textDelta("迟到的文字"))               // and nothing of a finished run may act again
    #expect(rig.cues.count == before)
}

@Test func aFailureCarriesTheRunnersCodeAndNothingElseActsAfterIt() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .failed, reason: "provider_error"))
    #expect(rig.cue.phase == .failed && rig.cue.event == .failed && rig.cue.detail == "provider_error")
    let before = rig.cues.count
    rig.agent(.runFailed, .message("provider_error"))
    #expect(rig.cues.count == before)
}

@Test func aToolIsWorkingOnlyWhileItExecutes() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.modelCompleted, .modelFinished(providerId: "cloud", finish: .toolCalls))
    rig.agent(.runState, state(.running, .awaitingTool))
    #expect(rig.cue.phase == .thinking, "the state alone is not work: no tool has started")
    let started = rig.agent(.toolStarted, .toolCall(callId: "c1", name: "send_message"), step: "c1")
    #expect(started.map(\.event) == [.toolStarted] && started.first?.detail == "communicate")
    #expect(rig.cue.phase == .working && rig.cue.operation == .communicate)
    let again = rig.agent(.toolProgress, activity("c1", .running), step: "c1")
    #expect(again.isEmpty, "the runner announces a start twice; the character must see it once")
    rig.agent(.toolCompleted, .toolSummary(callId: "c1", name: "send_message", summary: "已发送"), step: "c1")
    #expect(rig.cue.event == .toolSucceeded && rig.cue.phase == .thinking && rig.cue.operation == nil)
    #expect(rig.agent(.toolProgress, activity("c1", .succeeded), step: "c1").isEmpty)
}

@Test func theOperationFallsBackToTheToolKindWhenTheTableHasNoEntry() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.toolProgress, activity("w1", .running, name: "mystery_web", kind: .web), step: "w1")
    #expect(rig.cue.phase == .working && rig.cue.operation == .lookup)
    rig.agent(.toolProgress, activity("w1", .succeeded, name: "mystery_web", kind: .web), step: "w1")
    rig.agent(.toolProgress, activity("t2", .running, name: "mystery_tool"), step: "t2")
    #expect(rig.cue.operation == CompanionOperation.other)
}

@Test func loadingASkillIsNotToolWork() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.toolProgress, activity("s1", .succeeded, name: "load_skill", kind: .skill), step: "s1")
    #expect(rig.cue.phase == .thinking)
    rig.agent(.skillLoaded, .skill(id: "calendar", method: "model"), step: "s1")
    #expect(rig.cue.phase == .thinking && rig.cue.operation == nil)
}

// MARK: - Runtime truth over expressive intent

@Test func aSuccessfulRunMayCelebrateOnlyOnceItHasSucceeded() {
    var rig = Rig()
    rig.startTextRun()
    rig.toolRound("c1", ok: true)
    rig.answer("日程已创建！", tone: "celebrating", intensity: 0.9)
    #expect(rig.cue.intent == .neutral, "the answer is still being produced: never success before real success")
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.phase == .completed)
    #expect(rig.cue.intent == .celebrating && rig.cue.intensity == 0.9 && rig.cue.intentSource == .model)
    #expect(rig.cue.confidence == nil)
}

@Test func aFailedToolNeverYieldsACelebration() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.toolStarted, .toolCall(callId: "c1", name: "create_event"), step: "c1")
    let failed = rig.agent(.toolFailed, .toolError(callId: "c1", name: "create_event", code: "failed"), step: "c1")
    #expect(failed.map(\.event) == [.toolFailed])
    #expect(rig.agent(.toolProgress, activity("c1", .failed, name: "create_event"), step: "c1").isEmpty, "reported twice, counted once")
    rig.answer("搞定了！", tone: "celebrating")
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.phase == .completed)
    #expect(rig.cue.intent == .neutral && rig.cue.intentSource == .none)
}

@Test func failureBlocksLightHeartedToneButNotTheHonestOnes() {
    let cases: [(String, CompanionIntent)] = [("playful", .neutral), ("celebrating", .neutral), ("apologetic", .apologetic),
                                              ("cautious", .cautious), ("encouraging", .encouraging), ("comforting", .comforting)]
    for (label, expected) in cases {
        var rig = Rig()
        rig.startTextRun()
        rig.toolRound("c1", ok: false)
        rig.answer("没能完成。", tone: label)
        rig.agent(.runState, state(.running, .completed))
        #expect(rig.cue.intent == expected, "\(label)")
    }
}

@Test func permissionAndDeclinedOutcomesAlsoBlockCelebration() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.toolFailed, .toolError(callId: "c1", name: "create_event", code: "permission_openSettings"), step: "c1")
    rig.answer("好了！", tone: "celebrating")
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.intent == .neutral)

    var declined = Rig()
    declined.startTextRun()
    declined.agent(.approvalRequested, approval("c1", approved: nil), step: "c1")
    declined.agent(.toolProgress, activity("c1", .declined, kind: .approval), step: "c1")
    declined.agent(.approvalResolved, approval("c1", approved: false), step: "c1")
    declined.answer("好了！", tone: "celebrating")
    declined.agent(.runState, state(.running, .completed))
    #expect(declined.cue.intent == .neutral)
}

@Test func theRunnersOwnGuardEventsAndRetriedMalformedCallsAreNotFailures() {
    var rig = Rig()
    rig.startTextRun()
    for name in ["fabricated_claim", "skipped_tool", "unsupported_figures"] {
        #expect(rig.agent(.toolFailed, .toolError(callId: "model-1", name: name, code: "claim_without_tool")).isEmpty)
    }
    // A malformed call is rejected and retried by the model: a quiet step, not a failure.
    rig.agent(.toolProposed, .toolCall(callId: "bad", name: "create_event"), step: "bad")
    rig.agent(.toolFailed, .toolError(callId: "bad", name: "create_event", code: "invalid_arguments"), step: "bad")
    rig.agent(.toolProgress, activity("bad", .failed, name: "create_event"), step: "bad")
    #expect(rig.cue.phase == .thinking)
    rig.toolRound("good", ok: true)
    rig.answer("已创建！", tone: "celebrating")
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.intent == .celebrating)
}

@Test func expressionNeverAppliesToAFailedCancelledOrInterruptedTurn() {
    var failed = Rig()
    failed.startTextRun()
    failed.answer("出错了。", tone: "apologetic")
    #expect(failed.cue.intent == .neutral, "an answer's tone is shown while it is being delivered, not before text exists")
    failed.agent(.runState, state(.running, .failed, reason: "provider_error"))
    #expect(failed.cue.phase == .failed && failed.cue.intent == .neutral)

    var cancelled = Rig()
    cancelled.startTextRun()
    cancelled.answer("好的。", tone: "encouraging")
    cancelled.agent(.runState, state(.running, .cancelled))
    #expect(cancelled.cue.phase == .cancelled && cancelled.cue.intent == .neutral)
}

@Test func theIntentFollowsTheLatestSegmentOfATextTurn() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.companionSegment, .segment(ToneSegment(index: 0, offset: 0, label: "curious")))
    rig.agent(.modelDelta, .textDelta("为什么呢？"))
    #expect(rig.cue.intent == .curious && rig.cue.segment == 0)
    rig.agent(.companionSegment, .segment(ToneSegment(index: 1, offset: 5, label: "explaining", intensity: 0.6)))
    #expect(rig.cue.event == .segmentStarted || rig.cue.intent == .explaining)
    rig.agent(.modelDelta, .textDelta("因为……"))
    #expect(rig.cue.intent == .explaining && rig.cue.segment == 1 && rig.cue.intensity == 0.6)
    rig.agent(.companionSegment, .segment(ToneSegment(index: 2, offset: 8, label: "banana")))
    #expect(rig.cue.intent == .neutral && rig.cue.intentSource == .none, "an unknown declaration is neutral")
}

// MARK: - Approvals

@Test func waitingForAnApprovalIsNeverWorking() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.toolProposed, .toolCall(callId: "c1", name: "send_message"), step: "c1")
    rig.agent(.runState, state(.running, .awaitingApproval))
    rig.agent(.approvalRequested, approval("c1", approved: nil), step: "c1")
    rig.agent(.toolProgress, activity("c1", .awaitingApproval, kind: .approval), step: "c1")
    #expect(rig.cue.phase == .awaitingApproval && rig.cue.operation == nil)
    #expect(rig.cues.contains { $0.event == .approvalRequested })
    rig.answer("等你确认", tone: "celebrating")
    #expect(rig.cue.intent == .neutral, "only cautious/focused may show while waiting")

    // Approved: nothing executes until the tool really starts.
    rig.agent(.toolProgress, activity("c1", .running, kind: .approval), step: "c1")
    rig.agent(.approvalResolved, approval("c1", approved: true), step: "c1")
    #expect(rig.cue.event == .approvalResolved && rig.cue.detail == "approved")
    rig.agent(.runState, state(.awaitingApproval, .running))
    #expect(rig.cue.phase == .thinking)
    rig.agent(.runState, state(.running, .awaitingTool))
    rig.agent(.toolStarted, .toolCall(callId: "c1", name: "send_message"), step: "c1")
    #expect(rig.cue.phase == .working && rig.cue.operation == .communicate)
}

@Test func aDeclinedApprovalReturnsToThinking() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .awaitingApproval))
    rig.agent(.approvalRequested, approval("c1", approved: nil), step: "c1")
    #expect(rig.cue.phase == .awaitingApproval)
    rig.agent(.toolProgress, activity("c1", .declined, kind: .approval), step: "c1")
    rig.agent(.approvalResolved, approval("c1", approved: false), step: "c1")
    rig.agent(.runState, state(.awaitingApproval, .running))
    #expect(rig.cue.phase == .thinking && rig.cue.detail == nil || rig.cue.phase == .thinking)
    #expect(rig.cues.contains { $0.event == .approvalResolved && $0.detail == "declined" })
}

@Test func anExpiredApprovalEndsTheRunWithoutSuccess() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .awaitingApproval))
    rig.agent(.approvalRequested, approval("c1", approved: nil), step: "c1")
    rig.agent(.runState, state(.awaitingApproval, .expired, reason: "approval_expired"))
    #expect(rig.cue.phase == .cancelled && rig.cue.detail == "expired")
}

@Test func theVoiceLayersConfirmationCountsAsAwaitingApproval() {
    var rig = Rig()
    rig.voice(.phase(.thinking, turn: rig.turn, conversation: rig.conv, spoken: false))
    rig.voice(.phase(.confirming, turn: rig.turn, conversation: rig.conv, spoken: false))
    #expect(rig.cue.phase == .awaitingApproval)
    rig.voice(.phase(.thinking, turn: rig.turn, conversation: rig.conv, spoken: false))
    #expect(rig.cue.phase == .thinking)
}

// MARK: - Reconnection and ordering

@Test func aDroppedConnectionIsReportedAndReplaysNeverRepeat() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.modelDelta, .textDelta("第一"))
    let dropSequence = rig.seq + 1
    let dropped = rig.agent(.runState, state(.running, .awaitingNetwork, reason: "network"))
    #expect(dropped.map(\.event) == [.reconnecting] && dropped.first?.detail == "network")
    #expect(rig.cue.connectivity == .reconnecting && rig.cue.phase == .thinking)
    #expect(rig.agent(.runState, state(.running, .awaitingNetwork), sequence: dropSequence).isEmpty, "the same event again: ignored")

    let resumed = rig.agent(.runState, state(.awaitingNetwork, .resuming))
    #expect(resumed.map(\.event) == [.resumed] && rig.cue.connectivity == .live)
    #expect(rig.agent(.runResumed, .message("resumed")).isEmpty)

    // A reconnecting reader may deliver the whole early log again; none of it acts a second time.
    let high = rig.seq, count = rig.cues.count
    for s in 1...high { rig.agent(.modelDelta, .textDelta("重复"), sequence: s) }
    rig.seq = high
    #expect(rig.cues.count == count)

    rig.agent(.runState, state(.resuming, .running))
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cues.filter { $0.event == .completed }.count == 1)
    rig.agent(.runCompleted, .message("completed"), sequence: rig.seq)
    #expect(rig.cues.filter { $0.event == .completed }.count == 1)
    #expect(strictlyIncreasing(rig.cues))
}

@Test func aSuspendedRunIsPausedNotReconnecting() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .awaitingForeground, reason: "suspended"))
    #expect(rig.cue.connectivity == .paused && rig.cue.phase == .thinking)
    rig.agent(.runState, state(.awaitingForeground, .resuming))
    #expect(rig.cue.connectivity == .live)
}

@Test func switchingModelsMidRunIsReportedAndExpressionStartsOver() {
    var rig = Rig()
    rig.startTextRun(provider: "local-2b")
    rig.agent(.companionSegment, .segment(ToneSegment(index: 0, offset: 0, label: "comforting")))
    rig.agent(.modelDelta, .textDelta("没事的。"))
    #expect(rig.cue.intent == .comforting)
    rig.agent(.modelCompleted, .modelFinished(providerId: "local-2b", finish: .toolCalls))
    let same = rig.agent(.modelStarted, .modelRequest(providerId: "local-2b", step: 2), step: "model-2")
    #expect(same.allSatisfy { $0.event != .modelSwitched })

    let switched = rig.agent(.modelStarted, .modelRequest(providerId: "iTalk-cloud", step: 3), step: "model-3")
    #expect(switched.map(\.event) == [.modelSwitched] && switched.first?.detail == "iTalk-cloud")
    #expect(rig.cue.providerId == "iTalk-cloud")
    rig.agent(.modelDelta, .textDelta("原因是……"), step: "model-3")
    #expect(rig.cue.answering && rig.cue.intent == .neutral, "the new model has declared nothing: the old segment does not carry over")
    rig.agent(.companionSegment, .segment(ToneSegment(index: 0, offset: 0, label: "explaining")), step: "model-3")
    #expect(rig.cue.intent == .explaining)
}

@Test func eachRunOfAConversationIsATurnOfItsOwn() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .completed))
    let first = rig.cue.turnId
    rig.run = UUID(); rig.seq = 0
    rig.startTextRun()
    #expect(rig.cue.phase == .thinking && rig.cue.turnId != first && rig.cue.event != .completed)
    #expect(rig.cues.contains { $0.event == .turnStarted && $0.turnId == rig.cue.turnId })
    #expect(strictlyIncreasing(rig.cues))
}

@Test func runsOfOtherConversationsNeverMoveTheCharacter() {
    var rig = Rig()
    let other = UUID(), otherRun = UUID()
    rig.voice(.focus(conversation: rig.conv))
    #expect(rig.agent(.runCreated, .message("text"), run: otherRun, conversation: other).isEmpty)
    rig.agent(.modelStarted, .modelRequest(providerId: "cloud", step: 1), run: otherRun, conversation: other)
    #expect(rig.cue.phase == .idle)
    rig.startTextRun()
    #expect(rig.cue.phase == .thinking)
    let before = rig.cues.count
    rig.agent(.toolStarted, .toolCall(callId: "x", name: "send_message"), step: "x", run: otherRun, conversation: other)
    rig.agent(.runState, state(.running, .failed, reason: "boom"), run: otherRun, conversation: other)
    #expect(rig.cues.count == before && rig.cue.phase == .thinking)
}

@Test func aRemoteTaskCarriesItsOriginAndTaskId() {
    var rig = Rig()
    rig.agent(.runCreated, .message("remote"), origin: .macAgent, taskId: "task-7")
    rig.agent(.runState, state(.created, .running), origin: .macAgent, taskId: "task-7")
    #expect(rig.cue.origin == .macAgent && rig.cue.taskId == "task-7" && rig.cue.phase == .thinking)
}

@Test func progressIsNilUnlessAProducerReportsIt() {
    var rig = Rig()
    rig.startTextRun()
    #expect(rig.cue.progress == nil)
    rig.apply(.progress(runId: rig.run, fraction: 0.4))
    #expect(rig.cue.progress == 0.4)
    rig.apply(.progress(runId: rig.run, fraction: .nan))
    #expect(rig.cue.progress == 0)
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.progress == nil)
}

// MARK: - Outcomes settle

@Test func anOutcomeSettlesToIdleOnlyForItsOwnSequence() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .completed))
    let outcome = rig.cue
    #expect(rig.apply(.settle(afterSequence: outcome.sequence + 5)).isEmpty && rig.cue.phase == .completed)
    let settled = rig.apply(.settle(afterSequence: outcome.sequence))
    #expect(settled.count == 1 && rig.cue.phase == .idle && rig.cue.turnId == nil && rig.cue.runId == nil && rig.cue.intent == .neutral)
    #expect(rig.apply(.settle(afterSequence: outcome.sequence)).isEmpty, "a stale timer does nothing")
    rig.agent(.modelDelta, .textDelta("迟到"))
    #expect(rig.cue.phase == .idle, "a finished run cannot restart the character")
}

@Test func aNewTurnReplacesAStickyOutcome() {
    var rig = Rig()
    rig.startTextRun()
    rig.agent(.runState, state(.running, .completed))
    #expect(rig.cue.phase == .completed)
    let next = UUID()
    let out = rig.voice(.phase(.thinking, turn: next, conversation: rig.conv, spoken: false))
    #expect(out.first?.event == .turnStarted && rig.cue.phase == .thinking && rig.cue.turnId == next)
}

// MARK: - Voice

@Test func aSpokenTurnCompletesOnlyWhenTheAudioHasEnded() {
    var rig = Rig()
    let t = rig.turn, c = rig.conv
    rig.voice(.micPreparing)
    rig.voice(.phase(.preparing, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .preparing && rig.cue.mic.availability == .preparing && rig.cue.mic.level == nil)
    rig.voice(.phase(.listening, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .preparing, "audio is not flowing yet: not listening")
    rig.voice(.micLive)
    #expect(rig.cue.phase == .listening && rig.cue.mic.availability == .live)
    #expect(rig.cue.mic.level == nil, "live but nothing measured yet is no signal, not silence")
    rig.voice(.micLevel(0.4), dt: 0.1)
    #expect(rig.cue.mic.level == 0.4)
    rig.voice(.micVoice(true))
    #expect(rig.cue.event == .userSpeechStarted && rig.cue.mic.active)
    rig.voice(.micVoice(false))
    #expect(rig.cue.event == .userSpeechEnded && !rig.cue.mic.active)
    rig.voice(.phase(.finalizing, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .transcribing && rig.cue.mic.level == nil && rig.cue.mic.availability == .live)
    rig.voice(.phase(.thinking, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .thinking)

    rig.startTextRun(turn: t)
    rig.answer("你好。", turn: t)
    rig.agent(.runState, state(.running, .completed), turn: t)
    #expect(rig.cue.phase == .thinking, "the answer exists but nobody has heard it: not completed")
    rig.voice(.phase(.synthesizing, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.speech.availability == .preparing && rig.cue.phase == .thinking)
    rig.voice(.phase(.speaking, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .speaking && rig.cue.speech.availability == .live && rig.cue.speech.level == nil)
    rig.voice(.speechLevel(0.5), dt: 0.1)
    #expect(rig.cue.speech.level == 0.5 && rig.cue.speech.active)
    rig.voice(.phase(.idle, turn: t, conversation: c, spoken: true))
    #expect(rig.cue.phase == .completed && rig.cue.event == .completed)
    #expect(rig.cue.speech == .off)
    #expect(strictlyIncreasing(rig.cues))
}

@Test func thePhaseNeverClaimsListeningBeforeAudioFlows() {
    var rig = Rig()
    // The microphone level callback is itself the proof that audio flows, even if no stage event arrived.
    rig.voice(.phase(.listening, turn: rig.turn, conversation: rig.conv, spoken: true))
    #expect(rig.cue.phase != .listening)
    rig.voice(.micLevel(0.2), dt: 0.1)
    #expect(rig.cue.phase == .listening && rig.cue.mic.level == 0.2)
    rig.voice(.micOff)
    #expect(rig.cue.mic == .off && rig.cue.phase == .preparing, "no microphone: no listening")
}

@Test func aBargeInSilencesSpeechAtOnceAndDropsEverythingLateOfThatTurn() {
    var rig = Rig()
    let t = rig.turn, c = rig.conv
    rig.spokenTurnSpeaking()
    rig.voice(.speechLevel(0.6), dt: 0.1)
    #expect(rig.cue.phase == .speaking && rig.cue.speech.level == 0.6)

    rig.voice(.speechStopped(turn: t, cause: .userSpeech))
    #expect(rig.cue.speech == .off && rig.cue.event == .speechEnded && rig.cue.detail == "user_speech")
    rig.voice(.turnEnded(turn: t, cause: .userSpeech))
    #expect(rig.cue.phase == .interrupted && rig.cue.event == .interrupted && rig.cue.detail == "user_speech")

    let before = rig.cues.count
    rig.voice(.speechLevel(0.9), dt: 0.1)
    rig.voice(.speechChunkStarted(turn: t, sourceStart: 10))
    rig.voice(.phase(.speaking, turn: t, conversation: c, spoken: true))
    rig.voice(.speechPreparing(turn: t))
    rig.agent(.modelDelta, .textDelta("还在生成"), step: "model-2", turn: t)
    rig.agent(.runCancelled, .message("cancelled"), turn: t)
    #expect(rig.cues.count == before, "nothing of the interrupted turn may act again")
    #expect(rig.cue.speech == .off)

    let next = UUID()
    rig.voice(.phase(.preparing, turn: next, conversation: c, spoken: true))
    rig.voice(.micLive)
    rig.voice(.phase(.listening, turn: next, conversation: c, spoken: true))
    #expect(rig.cue.phase == .listening && rig.cue.turnId == next && rig.cue.speech == .off)
    #expect(strictlyIncreasing(rig.cues))
}

@Test func theStopButtonCancelsAndAnAgentSideCancelDoesNotPreemptTheVoiceLayer() {
    var stopped = Rig()
    stopped.spokenTurnSpeaking(runCompleted: false)
    stopped.voice(.turnEnded(turn: stopped.turn, cause: .userStop))
    #expect(stopped.cue.phase == .cancelled && stopped.cue.detail == "user_stop" && stopped.cue.speech == .off)

    // The run's cancellation event may arrive before the voice layer reports why: the voice layer decides.
    var barge = Rig()
    barge.spokenTurnSpeaking(runCompleted: false)
    barge.agent(.runState, state(.running, .cancelled), turn: barge.turn)
    #expect(barge.cue.phase != .cancelled)
    barge.voice(.turnEnded(turn: barge.turn, cause: .userSpeech))
    #expect(barge.cue.phase == .interrupted)

    // A turn without a voice layer (a remote task) is cancelled by the cancellation itself.
    var remote = Rig()
    remote.agent(.runCreated, .message("remote"), origin: .macAgent)
    remote.agent(.runState, state(.created, .cancelled))
    #expect(remote.cue.phase == .cancelled)
}

@Test func aFailureMidSpeechEndsTheAudioCues() {
    var rig = Rig()
    rig.spokenTurnSpeaking()
    rig.voice(.speechLevel(0.5), dt: 0.1)
    rig.voice(.turnEnded(turn: rig.turn, cause: .error))
    #expect(rig.cue.phase == .failed && rig.cue.speech == .off)
    #expect(rig.voice(.speechLevel(0.5), dt: 0.1).isEmpty)
}

@Test func theVoiceLayerMayEndBeforeTheLastAgentEventArrives() {
    // The agent events and the voice phases travel on different queues; both orders give one completion.
    var early = Rig()
    early.voice(.phase(.thinking, turn: early.turn, conversation: early.conv, spoken: false))
    early.startTextRun(turn: early.turn)
    early.answer("好的。", turn: early.turn)
    early.voice(.phase(.idle, turn: early.turn, conversation: early.conv, spoken: false))
    #expect(early.cue.phase == .thinking, "the run has not reported completion yet")
    early.agent(.runState, state(.running, .completed), turn: early.turn)
    #expect(early.cues.filter { $0.event == .completed }.count == 1 && early.cue.phase == .completed)

    var late = Rig()
    late.voice(.phase(.thinking, turn: late.turn, conversation: late.conv, spoken: false))
    late.voice(.phase(.idle, turn: late.turn, conversation: late.conv, spoken: false))    // no run was ever bound: the turn needed no model
    #expect(late.cue.phase == .completed)
    late.startTextRun(turn: late.turn)
    late.agent(.runState, state(.running, .completed), turn: late.turn)
    #expect(late.cues.filter { $0.event == .completed }.count == 1)
}

@Test func aFailedRunEndsAVoiceTurnImmediately() {
    var rig = Rig()
    rig.voice(.phase(.thinking, turn: rig.turn, conversation: rig.conv, spoken: true))
    rig.startTextRun(turn: rig.turn)
    rig.agent(.runState, state(.running, .failed, reason: "context_too_large"), turn: rig.turn)
    #expect(rig.cue.phase == .failed && rig.cue.detail == "context_too_large")
    rig.voice(.phase(.failed, turn: rig.turn, conversation: rig.conv, spoken: true))
    rig.voice(.turnEnded(turn: rig.turn, cause: .error))
    #expect(rig.cues.filter { $0.event == .failed }.count == 1)
}

// MARK: - Levels

@Test func microphoneLevelsAreThrottledAndOnlyReportedWhileListening() {
    var rig = Rig()
    rig.voice(.micPreparing); rig.voice(.phase(.preparing, turn: rig.turn, conversation: rig.conv, spoken: true))
    rig.voice(.micLive); rig.voice(.phase(.listening, turn: rig.turn, conversation: rig.conv, spoken: true))
    var levelCues = 0
    for i in 0..<40 { levelCues += rig.voice(.micLevel(Double(i % 10) / 10), dt: 0.001).filter { $0.event == .level }.count }
    #expect((1...2).contains(levelCues), "40 buffers in 40 ms may produce at most two cues, got \(levelCues)")
    levelCues = 0
    for i in 0..<100 { levelCues += rig.voice(.micLevel(Double(i % 10) / 10), dt: 0.01).filter { $0.event == .level }.count }   // 100 Hz for one second
    #expect(levelCues <= 31, "got \(levelCues)")
    #expect(strictlyIncreasing(rig.cues))

    rig.voice(.phase(.thinking, turn: rig.turn, conversation: rig.conv, spoken: true))
    #expect(rig.voice(.micLevel(0.9), dt: 0.1).isEmpty)
    #expect(rig.cue.mic.availability == .live && rig.cue.mic.level == nil, "the microphone is open but nothing attends to it")
}

@Test func smallLevelWigglesAreNotCues() {
    var rig = Rig()
    rig.voice(.micLive); rig.voice(.phase(.listening, turn: rig.turn, conversation: rig.conv, spoken: true))
    rig.voice(.micLevel(0.50), dt: 0.1)
    #expect(rig.voice(.micLevel(0.51), dt: 0.1).isEmpty)
    #expect(rig.voice(.micLevel(0.55), dt: 0.1).count == 1)
}

@Test func speechLevelsAreClampedAndNoSignalIsNotSilence() {
    var rig = Rig()
    rig.spokenTurnSpeaking()
    #expect(rig.cue.speech.availability == .live && rig.cue.speech.level == nil, "a voice that cannot be metered reports no level")
    rig.voice(.speechLevel(.nan), dt: 0.1)
    #expect(rig.cue.speech.level == 0 && !rig.cue.speech.active, "measured silence")
    rig.voice(.speechLevel(5), dt: 0.1)
    #expect(rig.cue.speech.level == 1 && rig.cue.speech.active)
    rig.voice(.speechLevel(-2), dt: 0.1)
    #expect(rig.cue.speech.level == 0)
    rig.voice(.speechStopped(turn: rig.turn, cause: .userStop))
    #expect(rig.cue.speech.level == nil && rig.cue.speech.availability == .off)
}

@Test func speechLevelsOfAnotherTurnOrBeforeAudioAreIgnored() {
    var rig = Rig()
    rig.voice(.phase(.thinking, turn: rig.turn, conversation: rig.conv, spoken: true))
    #expect(rig.voice(.speechLevel(0.8), dt: 0.1).isEmpty)
    rig.voice(.speechPreparing(turn: UUID()))
    #expect(rig.cue.speech == .off)
    rig.voice(.speechPreparing(turn: rig.turn))
    #expect(rig.cue.speech.availability == .preparing || rig.cue.speech == .off)
}

// MARK: - The speech clock

@Test func aSpokenTurnFollowsTheChunkBeingPlayedNotTheTextBeingGenerated() {
    var rig = Rig()
    let t = rig.turn
    rig.voice(.phase(.thinking, turn: t, conversation: rig.conv, spoken: true))
    rig.startTextRun(turn: t)
    rig.toolRound("c1", ok: true, turn: t)
    rig.agent(.modelStarted, .modelRequest(providerId: "cloud", step: 2), step: "model-2", turn: t)
    rig.agent(.companionSegment, .segment(ToneSegment(index: 0, offset: 0, label: "comforting")), step: "model-2", turn: t)
    rig.agent(.modelDelta, .textDelta("别担心，没事的。"), step: "model-2", turn: t)
    rig.agent(.companionSegment, .segment(ToneSegment(index: 1, offset: 8, label: "celebrating", intensity: 0.9)), step: "model-2", turn: t)
    rig.agent(.modelDelta, .textDelta("已经办好了！"), step: "model-2", turn: t)
    rig.agent(.modelCompleted, .modelFinished(providerId: "cloud", finish: .stop), step: "model-2", turn: t)
    rig.agent(.runState, state(.running, .completed), turn: t)
    rig.voice(.phase(.synthesizing, turn: t, conversation: rig.conv, spoken: true))
    rig.voice(.phase(.speaking, turn: t, conversation: rig.conv, spoken: true))
    #expect(rig.cue.phase == .speaking && rig.cue.intent == .neutral, "nothing of the answer has been spoken yet")

    rig.voice(.speechChunkStarted(turn: t, sourceStart: 0))
    #expect(rig.cue.intent == .comforting && rig.cue.segment == 0 && rig.cue.event == .segmentStarted)
    rig.voice(.speechChunkStarted(turn: t, sourceStart: 4))
    #expect(rig.cue.intent == .comforting)
    rig.voice(.speechChunkStarted(turn: t, sourceStart: 8))
    #expect(rig.cue.intent == .celebrating && rig.cue.segment == 1 && rig.cue.intensity == 0.9 && rig.cue.event == .segmentStarted)
}

@Test func aSpokenCelebrationAfterAFailedToolStaysNeutral() {
    var rig = Rig()
    rig.spokenTurnSpeaking(tone: "celebrating", toolOK: false, text: "搞定了！")
    rig.voice(.speechChunkStarted(turn: rig.turn, sourceStart: 0))
    #expect(rig.cue.phase == .speaking && rig.cue.intent == .neutral)
}

@Test func aSpokenCelebrationWaitsForTheRunToHaveSucceeded() {
    var rig = Rig()
    rig.spokenTurnSpeaking(runCompleted: false, tone: "celebrating", toolOK: true, text: "搞定了！")
    rig.voice(.speechChunkStarted(turn: rig.turn, sourceStart: 0))
    #expect(rig.cue.intent == .neutral, "the run is not finished")
    rig.agent(.runState, state(.running, .completed), turn: rig.turn)
    #expect(rig.cue.intent == .celebrating, "re-evaluated the moment the run has really succeeded")
}
