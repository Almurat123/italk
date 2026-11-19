import Foundation

public struct ImageAttachment: Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    public init(id: UUID = UUID(), data: Data) { self.id = id; self.data = data }
}

/// One visible step of an agent turn: loading a skill, running a tool, waiting for approval, or a permission problem.
/// Persistent: steps stay attached to their turn after the answer finishes and after relaunch.
public struct AgentStep: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case skill, tool, approval, web }
    public enum State: String, Codable, Sendable { case running, succeeded, failed, needsPermission, awaitingApproval, declined, cancelled }
    public struct Fact: Codable, Sendable, Equatable { public var label: String; public var value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value } }
    public struct Source: Codable, Sendable, Equatable, Identifiable { public var n: Int; public var title: String; public var url: String; public var snippet: String
        public var id: String { url }
        public init(n: Int, title: String, url: String, snippet: String = "") { self.n = n; self.title = title; self.url = url; self.snippet = snippet } }
    /// What the person can do about a failure.
    public enum Recovery: String, Codable, Sendable { case none, openSystemSettings, enableInITalk, retry }
    public var id: String                 // call id (or "skill-…")
    public var kind: Kind
    public var state: State
    public var title: String              // "查询日程", "搜索网页"
    public var detail: String             // what it is doing / the argument summary, one line
    public var summary: String            // result or failure, one line
    public var facts: [Fact]              // key figures for a native visualization (temperature, steps, ETA…)
    public var sources: [Source]
    public var recovery: Recovery
    public var permission: String?        // human label of the missing permission
    public var symbol: String
    public var startedAt: Date
    public var finishedAt: Date?
    public init(id: String, kind: Kind, state: State, title: String, detail: String = "", summary: String = "", facts: [Fact] = [], sources: [Source] = [],
                recovery: Recovery = .none, permission: String? = nil, symbol: String = "gearshape", startedAt: Date = .now, finishedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.state = state; self.title = title; self.detail = detail; self.summary = summary; self.facts = facts
        self.sources = sources; self.recovery = recovery; self.permission = permission; self.symbol = symbol; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct ConversationTurn: Identifiable, Sendable {
    public enum State: Sendable, Equatable { case pending, complete, cancelled, failed }
    public let id: UUID
    public let question: String
    public let images: [ImageAttachment]
    public var answer: String = ""
    public var state: State = .pending
    public var failure: String?
    /// Live and persisted agent activity for this turn (skills, tools, approvals, sources).
    public var steps: [AgentStep] = []
    public let createdAt: Date
    public init(id: UUID, question: String, images: [ImageAttachment] = [], createdAt: Date = .now) {
        self.id = id; self.question = question; self.images = images; self.createdAt = createdAt
    }
}

public struct HoldToTalkInteraction: Sendable {
    public private(set) var active = false
    public private(set) var willCancel = false
    public init() {}
    public mutating func begin() { active = true; willCancel = false }
    public mutating func move(horizontal: Double, vertical: Double) {
        guard active else { return }
        willCancel = horizontal < -70 || vertical < -80
    }
    @discardableResult public mutating func end() -> Bool {
        let accept = active && !willCancel
        active = false; willCancel = false
        return accept
    }
}

public enum CaptureDelivery: Sendable, Equatable { case conversation, dictation }

// CONTEXT MEMORY
// Updated: 2026-10-25
// Status: verified
// Why: Permission dialogs and model preparation can outlast a press gesture.
// Debug Goal: Releasing during preparation must not leave the microphone recording.
// Search Tags: hold to talk release while preparing finish requested
// Invariants:
// - A release is remembered until capture becomes ready.
// - A new gesture resets the previous release intent.
// Failure Modes:
// - A quick release is ignored and recording starts after the finger is lifted.
// - Silence endpoint detection sends dictation before user review.
public struct CaptureIntent: Sendable {
    public let delivery: CaptureDelivery
    public let held: Bool
    public private(set) var finishRequested = false
    public init(delivery: CaptureDelivery = .conversation, held: Bool = false) {
        self.delivery = delivery; self.held = held
    }
    public mutating func release() { finishRequested = true }
}

/// The model's own reasoning for one model step, exactly as streamed. Only exists for models that provide it.
public struct ReasoningBlock: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var finished: Bool
    public init(id: String, text: String, finished: Bool = false) { self.id = id; self.text = text; self.finished = finished }
}

/// Everything the agent did for one turn, in order: real model reasoning (when the model provides it) interleaved with execution
/// steps (skills, tools, confirmations, sources). While running it is shown live; when finished it collapses to one compact item
/// ("思考与执行 · 2分35秒") that expands to the full history. Persistent across relaunch.
public struct AgentTrace: Codable, Sendable, Equatable {
    public enum Item: Codable, Sendable, Equatable, Identifiable {
        case reasoning(ReasoningBlock)
        case step(AgentStep)
        public var id: String { switch self { case .reasoning(let r): "r-" + r.id; case .step(let s): "s-" + s.id } }
    }
    public enum State: String, Codable, Sendable { case running, paused, finished, cancelled, failed }
    public var items: [Item] = []
    public var state: State = .running
    public var startedAt: Date
    public var finishedAt: Date?
    /// Seconds of work so far (kept across relaunch so a resumed task does not count the time the app was gone).
    public var elapsed: TimeInterval = 0
    public init(startedAt: Date = .now) { self.startedAt = startedAt }

    public var reasoning: [ReasoningBlock] { items.compactMap { if case .reasoning(let r) = $0 { r } else { nil } } }
    public var steps: [AgentStep] { items.compactMap { if case .step(let s) = $0 { s } else { nil } } }
    public var hasReasoning: Bool { reasoning.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var isEmpty: Bool { items.isEmpty }
    public var isActive: Bool { state == .running }
    public var seconds: TimeInterval { finishedAt.map { max($0.timeIntervalSince(startedAt), elapsed) } ?? elapsed }

    /// "思考与执行 · 2分35秒": names only what really happened (reasoning only if the model provided it).
    public var summaryTitle: String {
        let what = hasReasoning ? (steps.contains { $0.kind != .skill } || !steps.isEmpty ? "思考与执行" : "思考") : "执行"
        return "\(what) · \(TraceDuration.text(seconds))"
    }
}

public enum TraceDuration {
    public static func text(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 1 { return "不到1秒" }
        if s < 60 { return "\(s)秒" }
        return s % 60 == 0 ? "\(s / 60)分钟" : "\(s / 60)分\(s % 60)秒"
    }
}
