import Testing
import Foundation
import AgentRuntime
@testable import RemoteAgent

private func ev(_ seq: Int, _ type: String, _ fields: [String: JSONValue] = [:]) -> RemoteEvent {
    RemoteEvent(seq: seq, type: type, data: .object(fields))
}

private struct Pipe {
    var bridge = RemoteCompanionBridge(taskId: "task-1", now: { Date(timeIntervalSince1970: 5) })
    var reducer = CompanionReducer(now: Date(timeIntervalSince1970: 100))
    var cues: [CompanionCue] = []
    var clock = Date(timeIntervalSince1970: 100)

    var cue: CompanionCue { reducer.cue }

    mutating func feed(_ inputs: [CompanionInput]) {
        for input in inputs { clock = clock.addingTimeInterval(0.05); cues += reducer.apply(input, at: clock) }
    }
    mutating func event(_ e: RemoteEvent) { feed(bridge.inputs(for: e)) }
    mutating func connection(_ s: RemoteConnectionStatus) { feed(bridge.connection(s)) }
}

private let started = ev(1, "started", ["backend": .string("builtin"), "model": .string("deepseek-flash"), "cwd": .string("/tmp"), "mode": .string("ask")])

@Test func aMacTaskWalksThroughThePhasesItReallyHad() {
    var p = Pipe()
    p.event(started)
    #expect(p.cue.phase == .thinking && p.cue.origin == .macAgent && p.cue.taskId == "task-1")
    #expect(p.cue.runId == p.bridge.runId && p.cue.conversationId == p.bridge.conversationId && p.cue.providerId == "mac/builtin/deepseek-flash")
    p.event(ev(2, "reasoning", ["text": .string("先看看目录")]))
    #expect(!p.cue.answering, "reasoning is not an answer")
    p.event(ev(3, "tool_call", ["id": .string("t1"), "name": .string("list_directory"), "summary": .string("列出目录"), "risk": .string("read")]))
    #expect(p.cue.phase == .working && p.cue.operation == .read)
    p.event(ev(4, "tool_result", ["id": .string("t1"), "ok": .bool(true), "preview": .string("3 项")]))
    #expect(p.cue.phase == .thinking && p.cue.operation == nil && p.cues.contains { $0.event == .toolSucceeded })
    p.event(ev(5, "text", ["text": .string("目录里有三个文件。")]))
    #expect(p.cue.answering && p.cue.phase == .thinking)
    p.event(ev(6, "usage", ["inputTokens": .number(10), "outputTokens": .number(5)]))
    p.event(ev(7, "completed"))
    #expect(p.cue.phase == .completed && p.cue.event == .completed && !p.cue.answering)
    #expect(p.cues.filter { $0.event == .modelSwitched }.isEmpty, "a new stretch of text after a tool is not a new model")
    #expect(zip(p.cues, p.cues.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
}

@Test func aFailedToolIsReportedAndATaskFailureCarriesItsCode() {
    var p = Pipe()
    p.event(started)
    p.event(ev(2, "tool_call", ["id": .string("t1"), "name": .string("run_command"), "risk": .string("modify")]))
    #expect(p.cue.operation == .control)
    p.event(ev(3, "tool_result", ["id": .string("t1"), "ok": .bool(false), "preview": .string("exit 1")]))
    #expect(p.cues.contains { $0.event == .toolFailed })
    p.event(ev(4, "failed", ["code": .string("provider_unreachable"), "message": .string("无法连接")]))
    #expect(p.cue.phase == .failed && p.cue.detail == "provider_unreachable")
}

@Test func anApprovalWaitIsNeverWorkAndTheOutcomesAreReal() {
    var approved = Pipe()
    approved.event(started)
    approved.event(ev(2, "approval_requested", ["approvalId": .string("a1"), "tool": .string("write_file"), "summary": .string("写入 notes.txt"), "risk": .string("modify")]))
    #expect(approved.cue.phase == .awaitingApproval && approved.cue.operation == nil)
    #expect(!approved.cues.contains { $0.phase == .working })
    approved.event(ev(3, "approval_resolved", ["approvalId": .string("a1"), "outcome": .string("approved"), "scope": .string("once")]))
    #expect(approved.cue.phase == .thinking && approved.cues.contains { $0.event == .approvalResolved && $0.detail == "approved" })
    approved.event(ev(4, "tool_call", ["id": .string("t1"), "name": .string("write_file")]))
    #expect(approved.cue.phase == .working && approved.cue.operation == .write)

    var declined = Pipe()
    declined.event(started)
    declined.event(ev(2, "approval_requested", ["approvalId": .string("a1"), "tool": .string("run_command"), "summary": .string("删除"), "risk": .string("sensitive")]))
    declined.event(ev(3, "approval_resolved", ["approvalId": .string("a1"), "outcome": .string("declined")]))
    #expect(declined.cue.phase == .thinking && !declined.cues.contains { $0.phase == .working })
    #expect(declined.cues.contains { $0.event == .approvalResolved && $0.detail == "declined" })

    var expired = Pipe()
    expired.event(started)
    expired.event(ev(2, "approval_requested", ["approvalId": .string("a1")]))
    expired.event(ev(3, "approval_resolved", ["approvalId": .string("a1"), "outcome": .string("expired")]))
    expired.event(ev(4, "failed", ["code": .string("approval_expired")]))
    #expect(expired.cue.phase == .failed)
}

@Test func aQuestionForThePersonIsAWaitToo() {
    var p = Pipe()
    p.event(started)
    p.event(ev(2, "question_requested", ["questionId": .string("q1"), "question": .string("用哪个文件夹？"), "choices": .array([.string("A"), .string("B")])]))
    #expect(p.cue.phase == .awaitingApproval)
    p.event(ev(3, "question_answered", ["questionId": .string("q1"), "answered": .bool(true), "answer": .string("A")]))
    #expect(p.cue.phase == .thinking)
}

@Test func aReplayAfterAReconnectNeverActsTwice() {
    var p = Pipe()
    let log = [started,
               ev(2, "tool_call", ["id": .string("t1"), "name": .string("read_file")]),
               ev(3, "tool_result", ["id": .string("t1"), "ok": .bool(true)]),
               ev(4, "text", ["text": .string("好了")])]
    for e in log { p.event(e) }
    let count = p.cues.count
    for e in log { p.event(e) }                    // the reader reconnected with an old `after`: the whole log again
    #expect(p.cues.count == count)
    p.event(ev(5, "completed"))
    p.event(ev(5, "completed"))
    p.event(ev(6, "text", ["text": .string("迟到")]))
    #expect(p.cues.filter { $0.event == .completed }.count == 1 && p.cue.phase == .completed)
    p.connection(.reconnecting(attempt: 1))
    #expect(p.cue.phase == .completed, "a finished task is never revived by the transport")
}

@Test func theTransportsReconnectionIsShownAndEnds() {
    var p = Pipe()
    p.connection(.reconnecting(attempt: 1))
    #expect(p.cue.phase == .idle, "nothing is known about a task that has not started")
    p.event(started)
    p.event(ev(2, "text", ["text": .string("正在")]))
    p.connection(.reconnecting(attempt: 1))
    #expect(p.cue.connectivity == .reconnecting && p.cue.event == .reconnecting && p.cue.phase == .thinking)
    let count = p.cues.count
    p.connection(.reconnecting(attempt: 2))
    #expect(p.cues.count == count, "attempts are not new events")
    p.connection(.connected)
    #expect(p.cue.connectivity == .live && p.cue.event == .resumed)
    p.connection(.connected)
    #expect(p.cues.filter { $0.event == .resumed }.count == 1)
    p.event(ev(3, "completed"))
    #expect(p.cue.phase == .completed)
}

@Test func anEventAfterAReconnectEndsTheWaitWithoutAnExplicitConnectedStatus() {
    var p = Pipe()
    p.event(started)
    p.connection(.reconnecting(attempt: 1))
    p.event(ev(2, "text", ["text": .string("继续")]))
    #expect(p.cue.connectivity == .live && p.cues.contains { $0.event == .resumed })
}

@Test func attachingToATaskInProgressStartsATurnFromTheFirstEvent() {
    var p = Pipe()
    p.event(ev(7, "tool_result", ["id": .string("t9"), "ok": .bool(true)]))
    #expect(p.cue.runId == p.bridge.runId && p.cue.origin == .macAgent)
    p.event(ev(8, "completed"))
    #expect(p.cue.phase == .completed)
}

@Test func aCancelledTaskEndsOnce() {
    var p = Pipe()
    p.event(started)
    p.event(ev(2, "cancelled"))
    #expect(p.cue.phase == .cancelled && p.cues.filter { $0.event == .cancelled }.count == 1)
}

@Test func identitiesAreStablePerTask() {
    let a = RemoteCompanionBridge(taskId: "task-1"), b = RemoteCompanionBridge(taskId: "task-1"), c = RemoteCompanionBridge(taskId: "task-2")
    #expect(a.runId == b.runId && a.conversationId == b.conversationId)
    #expect(a.runId != c.runId && a.conversationId != c.conversationId && a.runId != a.conversationId)
}

@Test func toolCategoriesComeFromFixedTables() {
    let cases: [(String, String?, CompanionOperation)] = [
        ("read_file", nil, .read), ("search_text", nil, .read), ("Grep", nil, .read), ("write_file", nil, .write), ("edit_file", nil, .write),
        ("Edit", nil, .write), ("run_command", nil, .control), ("Bash", nil, .control), ("WebSearch", nil, .lookup),
        ("mystery", "read", .read), ("mystery", "modify", .write), ("mystery", "external", .communicate), ("mystery", "sensitive", .control),
        ("mystery", nil, .other), ("mystery", "weird", .other),
    ]
    for (name, risk, expected) in cases { #expect(RemoteCompanionBridge.operation(forTool: name, risk: risk) == expected, "\(name) \(risk ?? "-")") }
}
