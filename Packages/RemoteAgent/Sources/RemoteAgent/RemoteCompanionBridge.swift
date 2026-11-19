import Foundation
import CryptoKit
import AgentRuntime

/// Re-expresses one Mac task's event log as the run events the companion reducer already understands, so a task on the person's
/// Mac and a run on the phone drive the character through the same rules (an approval wait is never "working", a failed tool never
/// celebrates, a replay after a reconnect never acts twice).
///
/// Nothing here is inferred from text. Every output follows from an event the Mac really sent (or from the transport reporting that
/// it is reconnecting). The Mac agent does not use the tone protocol, so no semantic intent exists for Mac tasks today: cues carry
/// runtime state only.
public struct RemoteCompanionBridge: Sendable {
    public let taskId: String
    /// Stable per task, so the same task is always the same run (also after the app restarts).
    public let runId: UUID
    /// A Mac task is its own conversation as far as the character is concerned (set `CompanionVoiceSignal.focus` to this id while the
    /// task is on screen).
    public let conversationId: UUID

    private let now: @Sendable () -> Date
    private var lastRemoteSeq = 0
    private var emitted = 0
    private var started = false
    private var openStep: Int?                 // a model "step" (a stretch of text) is open
    private var stepCount = 0
    private var provider = "mac"
    private var waitingForNetwork = false
    private var waitingForPerson = 0
    private var finished = false
    private var toolNames: [String: String] = [:]       // call id → tool name (the result event does not repeat it)

    public init(taskId: String, now: @escaping @Sendable () -> Date = { .now }) {
        self.taskId = taskId
        self.runId = Self.uuid("run|" + taskId)
        self.conversationId = Self.uuid("conversation|" + taskId)
        self.now = now
    }

    // MARK: Events

    /// The inputs for one Mac event. Events at or below the last sequence seen (a reader that reconnected and replays) produce nothing.
    public mutating func inputs(for event: RemoteEvent) -> [CompanionInput] {
        guard event.seq > lastRemoteSeq, !finished else { return [] }
        lastRemoteSeq = event.seq
        var out: [AgentEvent] = []
        begin(&out)
        if waitingForNetwork { waitingForNetwork = false; out.append(state(.awaitingNetwork, .running, reason: "reconnected")) }

        switch event.type {
        case "started":
            let backend = event.string("backend") ?? "mac", model = event.string("model")
            provider = model.map { "mac/\(backend)/\($0)" } ?? "mac/\(backend)"
            openModelStep(&out)
        case "text", "reasoning":
            guard !(event.string("text") ?? "").isEmpty else { break }
            openModelStep(&out)
            out.append(make(event.type == "text" ? .modelDelta : .reasoningDelta, step: "model-\(stepCount)", .textDelta(event.string("text") ?? "")))
        case "tool_call":
            closeModelStep(&out)
            let id = event.string("id") ?? "step-\(event.seq)", name = event.string("name") ?? "tool"
            toolNames[id] = name
            let op = Self.operation(forTool: name, risk: event.string("risk"))
            out.append(make(.toolStarted, step: id, .toolCall(callId: id, name: name)))
            out.append(make(.toolProgress, step: id, .activity(Self.activity(id, name, .running, op, summary: event.string("summary") ?? ""))))
        case "tool_result":
            closeModelStep(&out)
            let id = event.string("id") ?? "step-\(event.seq)"
            let name = toolNames[id] ?? event.string("name") ?? "tool"
            let op = Self.operation(forTool: name, risk: nil)
            if event.bool("ok") ?? false {
                out.append(make(.toolCompleted, step: id, .toolSummary(callId: id, name: name, summary: event.string("preview") ?? "")))
                out.append(make(.toolProgress, step: id, .activity(Self.activity(id, name, .succeeded, op, summary: event.string("preview") ?? ""))))
            } else {
                out.append(make(.toolFailed, step: id, .toolError(callId: id, name: name, code: "failed")))
                out.append(make(.toolProgress, step: id, .activity(Self.activity(id, name, .failed, op, summary: event.string("preview") ?? ""))))
            }
        case "approval_requested", "question_requested":
            closeModelStep(&out)
            let id = event.string("approvalId") ?? event.string("questionId") ?? "decision-\(event.seq)"
            waitingForPerson += 1
            out.append(state(.running, .awaitingApproval, reason: nil))
            out.append(make(.approvalRequested, step: id, .approval(approvalId: id, summary: event.string("summary") ?? event.string("question") ?? "", approved: nil)))
        case "approval_resolved", "question_answered":
            let id = event.string("approvalId") ?? event.string("questionId") ?? "decision-\(event.seq)"
            let approved: Bool
            if event.type == "approval_resolved" { approved = event.string("outcome") == "approved" } else { approved = event.bool("answered") ?? false }
            waitingForPerson = max(0, waitingForPerson - 1)
            if event.type == "approval_resolved", !approved {                // declined, expired or cancelled: the action did not run
                out.append(make(.toolProgress, step: id, .activity(Self.activity(id, "approval", .declined, nil, kind: .approval))))
            }
            out.append(make(.approvalResolved, step: id, .approval(approvalId: id, summary: "", approved: approved)))
            if waitingForPerson == 0 { out.append(state(.awaitingApproval, .running, reason: nil)) }
        case "completed":
            closeModelStep(&out)
            finished = true
            out.append(state(.running, .completed, reason: nil))
            out.append(make(.runCompleted, step: "done", .message("completed")))
        case "failed":
            closeModelStep(&out)
            finished = true
            let code = event.string("code") ?? "failed"
            out.append(state(.running, .failed, reason: code))
            out.append(make(.runFailed, step: "done", .message(code)))
        case "cancelled":
            closeModelStep(&out)
            finished = true
            out.append(state(.running, .cancelled, reason: "cancelled"))
            out.append(make(.runCancelled, step: "done", .message("cancelled")))
        default:                              // status, plan, usage: not part of the character's world
            break
        }
        return out.map { .agent($0, turn: nil, origin: .macAgent, taskId: taskId) }
    }

    /// The transport lost the Mac (the task keeps running there) or found it again.
    public mutating func connection(_ status: RemoteConnectionStatus) -> [CompanionInput] {
        guard !finished else { return [] }
        var out: [AgentEvent] = []
        switch status {
        case .reconnecting:
            guard started, !waitingForNetwork else { return [] }
            waitingForNetwork = true
            out.append(state(.running, .awaitingNetwork, reason: "reconnecting"))
        case .connected:
            guard waitingForNetwork else { return [] }
            waitingForNetwork = false
            out.append(state(.awaitingNetwork, .running, reason: "reconnected"))
        }
        return out.map { .agent($0, turn: nil, origin: .macAgent, taskId: taskId) }
    }

    // MARK: Categories

    /// What a tool does, from fixed tables over the tool names the Mac backends declare, then over the risk class the Mac assigned.
    /// Never from the wording of a summary.
    public static func operation(forTool name: String, risk: String?) -> CompanionOperation {
        switch name {
        case "read_file", "list_directory", "search_text", "Read", "Glob", "Grep", "LS", "NotebookRead": return .read
        case "write_file", "edit_file", "Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return .write
        case "run_command", "Bash", "shell", "exec", "terminal": return .control
        case "WebSearch", "WebFetch", "web_search", "web_fetch": return .lookup
        default: break
        }
        switch risk {
        case "read": return .read
        case "modify": return .write
        case "external": return .communicate
        case "sensitive": return .control
        default: return .other
        }
    }

    // MARK: Plumbing

    private mutating func begin(_ out: inout [AgentEvent]) {
        guard !started else { return }
        started = true
        out.append(make(.runCreated, step: "start", .message("remote")))
        out.append(state(.created, .running, reason: nil))
    }

    private mutating func openModelStep(_ out: inout [AgentEvent]) {
        guard openStep == nil else { return }
        stepCount += 1
        openStep = stepCount
        out.append(make(.modelStarted, step: "model-\(stepCount)", .modelRequest(providerId: provider, step: stepCount)))
    }

    private mutating func closeModelStep(_ out: inout [AgentEvent]) {
        guard openStep != nil else { return }
        out.append(make(.modelCompleted, step: "model-\(stepCount)", .modelFinished(providerId: provider, finish: .stop)))
        openStep = nil
    }

    private mutating func make(_ type: AgentEventType, step: String, _ payload: EventPayload) -> AgentEvent {
        emitted += 1
        return AgentEvent(eventId: UUID(), runId: runId, conversationId: conversationId, stepId: step, parentId: nil, sequence: emitted,
                          timestamp: now(), type: type, visibility: .activity, payload: payload)
    }

    private mutating func state(_ from: RunState, _ to: RunState, reason: String?) -> AgentEvent {
        make(.runState, step: "state", .state(from: from, to: to, reason: reason))
    }

    private static func activity(_ id: String, _ name: String, _ state: ToolActivity.State, _ op: CompanionOperation?,
                                 kind: ToolActivity.Kind = .tool, summary: String = "") -> ToolActivity {
        ToolActivity(callId: id, name: name, kind: kind, state: state, title: name, detail: "", summary: summary, facts: [], sources: [],
                     recovery: .none, permission: nil, symbol: "terminal", operation: op)
    }

    /// First 16 bytes of SHA-256, as a UUID: deterministic, collision-safe for task ids.
    private static func uuid(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
