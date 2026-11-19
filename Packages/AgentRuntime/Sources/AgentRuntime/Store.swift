import Foundation

public struct SideEffectRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case started, completed, outcomeUnknown }
    public var status: Status
    public var toolName: String
    public var output: ToolOutput?
}

public struct PendingInteraction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case toolApproval, userChoice }
    public var kind: Kind
    public var callId: String
    public var componentId: String
}

public struct ReasoningRecord: Codable, Sendable, Equatable {
    public var step: Int
    public var text: String
    public init(step: Int, text: String) { self.step = step; self.text = text }
}

public struct RunBudget: Codable, Sendable, Equatable {
    /// Multi-step browsing (search → open → follow → answer) needs room; runaway loops still stop.
    public var maxModelSteps = 12
    public var maxToolCalls = 24
    /// Includes time spent waiting for the person's confirmation.
    public var maxSeconds: Double = 1800
    public var maxCompletionTokens = 12000
    public init() {}
}

/// Authoritative, durable run state. SwiftUI never mutates it directly.
public struct RunSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion = RunSnapshot.schemaVersion
    public var runId: UUID
    public var conversationId: UUID
    public var state: RunState
    public var providerId: String
    public var messages: [ModelMessage]
    public var loadedSkills: [String]
    public var modelSteps = 0
    /// The model step currently being generated (set until its result is stored); a resumed run reuses it.
    public var inFlightStep: Int?
    public var toolCalls = 0
    public var completionTokens = 0
    public var usage: [Usage] = []
    public var components: [String: ComponentRecord] = [:]
    public var approvals: [String: Bool] = [:]          // callId -> approved
    public var choices: [String: String] = [:]          // callId -> optionId
    public var sideEffects: [String: SideEffectRecord] = [:]  // idempotencyKey -> record
    public var seenActionKeys: Set<String> = []
    public var pending: PendingInteraction?
    public var finalText: String?
    public var failure: String?
    /// Spoken turn: lean prompt (no tool schemas or skill catalog unless a skill was routed) and spoken-style answers.
    public var voice: Bool?
    /// The app's id for this turn (e.g. the user message id), so a run finishing later — after a conversation switch, a
    /// relaunch or a network recovery — is written to the right place.
    public var tag: String?
    /// Messages before this index were context; later ones belong to this run (narration, tool calls, final answer).
    public var contextCount: Int?
    /// Times the runtime corrected a completion claim that no tool had backed.
    public var nudges: Int?
    /// Skills the model chose in the guided selection step (nil = not asked yet or native mode; empty = it chose none).
    public var selection: [String]?
    /// The selector's raw reply (diagnostics only; short).
    public var selectionText: String?
    /// The run has read content the person did not write (web page, file, clipboard, image text). Standing grants stop applying.
    public var tainted: Bool?
    /// Tools are withheld and the model must answer with what it already has (tool loop or nearly out of budget).
    public var forceAnswer: Bool?
    /// The model's real reasoning per model step (only for models that provide it). Display and history only.
    public var reasoning: [ReasoningRecord]?
    /// How big each request of this run was and what was given up to fit it (numbers only; the last 16).
    public var contextReports: [ContextReport]?
    /// Numbers behind a `context_too_large` failure ("prompt 3302 + answer room 256 > window 4096"), for diagnostics; never conversation text.
    public var failureDetail: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var budget = RunBudget()
}

public protocol RunStore: Sendable {
    func save(_ snapshot: RunSnapshot) async throws
    func load(runId: UUID) async -> RunSnapshot?
    func listRunIds() async -> [UUID]
    func append(_ event: AgentEvent) async
    func events(runId: UUID, after sequence: Int) async -> [AgentEvent]
    func lastSequence(runId: UUID) async -> Int
}

public actor InMemoryRunStore: RunStore {
    private var snaps: [UUID: RunSnapshot] = [:]
    private var log: [UUID: [AgentEvent]] = [:]
    public init() {}
    public func save(_ s: RunSnapshot) { snaps[s.runId] = s }
    public func load(runId: UUID) -> RunSnapshot? { snaps[runId] }
    public func listRunIds() -> [UUID] { Array(snaps.keys) }
    public func append(_ e: AgentEvent) { log[e.runId, default: []].append(e) }
    public func events(runId: UUID, after sequence: Int) -> [AgentEvent] { (log[runId] ?? []).filter { $0.sequence > sequence } }
    public func lastSequence(runId: UUID) -> Int { log[runId]?.last?.sequence ?? 0 }
}

/// Snapshot = atomic JSON file. Events = append-only JSONL. Survives process termination.
public actor FileRunStore: RunStore {
    private let root: URL
    public init(directory: URL) throws {
        root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    private func snapURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).run.json") }
    private func logURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).events.jsonl") }

    public func save(_ s: RunSnapshot) throws {
        try AgentCoding.encoder().encode(s).write(to: snapURL(s.runId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func load(runId: UUID) -> RunSnapshot? {
        guard let d = try? Data(contentsOf: snapURL(runId)) else { return nil }
        return try? AgentCoding.decoder().decode(RunSnapshot.self, from: d)
    }
    public func listRunIds() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap {
            $0.hasSuffix(".run.json") ? UUID(uuidString: String($0.dropLast(".run.json".count))) : nil
        }
    }
    public func append(_ e: AgentEvent) {
        guard var line = try? AgentCoding.encoder().encode(e) else { return }
        line.append(0x0A)
        let url = logURL(e.runId)
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
        else { try? line.write(to: url, options: .atomic) }
    }
    public func events(runId: UUID, after sequence: Int) -> [AgentEvent] {
        guard let text = try? String(contentsOf: logURL(runId), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? AgentCoding.decoder().decode(AgentEvent.self, from: Data($0.utf8)) }.filter { $0.sequence > sequence }
    }
    public func lastSequence(runId: UUID) -> Int { events(runId: runId, after: 0).last?.sequence ?? 0 }
}
