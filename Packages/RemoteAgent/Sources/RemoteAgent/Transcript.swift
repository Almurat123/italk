import Foundation
import AgentRuntime

/// What a task on the computer has done so far, rebuilt from its event log. Applying the same events in order always gives the same result,
/// so a transcript can be dropped and rebuilt from the computer's durable log at any time.
public struct RemoteTranscript: Sendable, Equatable {
    public struct Step: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable { case running, succeeded, failed }
        public var id: String
        public var name: String
        public var summary: String
        public var risk: ToolRisk
        public var state: State
        public var preview: String?
    }
    public struct Approval: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable { case pending, approved, declined, expired, cancelled }
        public var id: String
        public var tool: String
        public var summary: String
        public var risk: ToolRisk
        public var tainted: Bool
        public var scopes: [String]
        public var expiresAt: Date
        public var state: State
    }
    public struct PlanItem: Sendable, Equatable { public var text: String; public var status: String }
    public struct Question: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable { case pending, answered(String), unanswered(reason: String) }
        public var id: String; public var text: String; public var choices: [String]; public var expiresAt: Date; public var state: State
    }
    public enum Item: Sendable, Equatable {
        case text(String), reasoning(String), step(String), note(String), approval(String), question(String)
    }
    public enum Phase: Sendable, Equatable { case running, completed, failed(code: String, message: String?), cancelled }

    public var items: [Item] = []
    public var steps: [String: Step] = [:]
    public var approvals: [String: Approval] = [:]
    /// The agent's own plan (the `todo` tool), always the latest complete list.
    public var plan: [PlanItem] = []
    public var questions: [String: Question] = [:]
    public var phase: Phase = .running
    public var lastSeq = 0
    public var inputTokens = 0, outputTokens = 0

    public init() {}

    /// The answer so far (all text blocks, in order).
    public var answer: String { items.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined() }
    public var reasoning: String { items.compactMap { if case .reasoning(let t) = $0 { t } else { nil } }.joined() }
    public var pendingApproval: Approval? { approvals.values.filter { $0.state == .pending }.min { $0.expiresAt < $1.expiresAt } }
    public var pendingQuestion: Question? { questions.values.filter { $0.state == .pending }.min { $0.expiresAt < $1.expiresAt } }
    public var isFinished: Bool { phase != .running }

    public mutating func apply(_ e: RemoteEvent) {
        guard e.seq > lastSeq else { return }
        lastSeq = e.seq
        switch e.type {
        case "text": append(.text, e.string("text") ?? "")
        case "reasoning": append(.reasoning, e.string("text") ?? "")
        case "status": if let m = e.string("message") { items.append(.note(m)) }
        case "tool_call":
            let id = e.string("id") ?? "step-\(e.seq)"
            steps[id] = Step(id: id, name: e.string("name") ?? "tool", summary: e.string("summary") ?? e.string("name") ?? "", risk: ToolRisk(rawValue: e.string("risk") ?? "") ?? .modify, state: .running, preview: nil)
            items.append(.step(id))
        case "tool_result":
            if let id = e.string("id"), var s = steps[id] { s.state = (e.bool("ok") ?? false) ? .succeeded : .failed; s.preview = e.string("preview"); steps[id] = s }
        case "approval_requested":
            let id = e.string("approvalId") ?? "approval-\(e.seq)"
            approvals[id] = Approval(id: id, tool: e.string("tool") ?? "", summary: e.string("summary") ?? "", risk: ToolRisk(rawValue: e.string("risk") ?? "") ?? .modify, tainted: e.bool("tainted") ?? false,
                                     scopes: e.strings("scopes"), expiresAt: Date(timeIntervalSince1970: (e.number("expiresAt") ?? 0) / 1000), state: .pending)
            items.append(.approval(id))
        case "approval_resolved":
            if let id = e.string("approvalId"), var a = approvals[id] { a.state = Approval.State(rawValue: e.string("outcome") ?? "") ?? .cancelled; approvals[id] = a }
        case "plan":
            if case .object(let o) = e.data, case .array(let list)? = o["items"] {
                plan = list.compactMap { v in
                    guard case .object(let i) = v, case .string(let t)? = i["text"] else { return nil }
                    if case .string(let st)? = i["status"] { return PlanItem(text: t, status: st) }
                    return PlanItem(text: t, status: "pending")
                }
            }
        case "question_requested":
            let id = e.string("questionId") ?? "question-\(e.seq)"
            questions[id] = Question(id: id, text: e.string("question") ?? "", choices: e.strings("choices"), expiresAt: Date(timeIntervalSince1970: (e.number("expiresAt") ?? 0) / 1000), state: .pending)
            items.append(.question(id))
        case "question_answered":
            if let id = e.string("questionId"), var q = questions[id] { q.state = (e.bool("answered") ?? false) ? .answered(e.string("answer") ?? "") : .unanswered(reason: e.string("reason") ?? "expired"); questions[id] = q }
        case "usage": inputTokens += Int(e.number("inputTokens") ?? 0); outputTokens += Int(e.number("outputTokens") ?? 0)
        case "completed": phase = .completed
        case "failed": phase = .failed(code: e.string("code") ?? "failed", message: e.string("message"))
        case "cancelled": phase = .cancelled
        default: break
        }
    }

    private enum Kind { case text, reasoning }
    private mutating func append(_ kind: Kind, _ piece: String) {
        guard !piece.isEmpty else { return }
        switch (kind, items.last) {
        case (.text, .text(let t)?): items[items.count - 1] = .text(t + piece)
        case (.reasoning, .reasoning(let t)?): items[items.count - 1] = .reasoning(t + piece)
        case (.text, _): items.append(.text(piece))
        case (.reasoning, _): items.append(.reasoning(piece))
        }
    }
}
