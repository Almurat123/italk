import Foundation

/// Durable record of every side-effecting tool execution, keyed by a stable execution id (`runId/callId`) and also
/// findable by content fingerprint within a conversation. Survives model switches, speech interruption, resume and restart.
public struct ExecutionRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case started, completed, failed, outcomeUnknown }
    public var executionId: String
    public var conversationId: UUID
    public var runId: UUID
    public var toolName: String
    /// Tool name + canonical arguments: the same action requested again (e.g. by another model after a switch).
    public var fingerprint: String
    public var status: Status
    public var output: ToolOutput?
    public var failure: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var id: String { executionId }

    public static func fingerprint(tool: String, arguments: JSONValue) -> String { "\(tool) \(arguments.compactString)" }
}

public actor ExecutionJournal {
    private var records: [String: ExecutionRecord] = [:]
    private let file: URL?

    /// `file`: JSON file for durability (nil = memory only, tests).
    public init(file: URL? = nil) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let list = try? AgentCoding.decoder().decode([ExecutionRecord].self, from: data) {
            for r in list { records[r.executionId] = r }
        }
    }

    public func record(_ r: ExecutionRecord) {
        records[r.executionId] = r
        save()
    }
    public func get(_ executionId: String) -> ExecutionRecord? { records[executionId] }

    /// A completed execution of exactly this action in this conversation, newer than `since`.
    public func completedDuplicate(conversationId: UUID, fingerprint: String, since: Date, excluding executionId: String) -> ExecutionRecord? {
        records.values.filter { $0.conversationId == conversationId && $0.fingerprint == fingerprint && $0.executionId != executionId
            && $0.status == .completed && $0.startedAt >= since }.max { $0.startedAt < $1.startedAt }
    }

    /// Task journal for a conversation (newest last) — shown as the conversation's activity history.
    public func history(conversationId: UUID) -> [ExecutionRecord] {
        records.values.filter { $0.conversationId == conversationId }.sorted { $0.startedAt < $1.startedAt }
    }

    private func save() {
        guard let file else { return }
        // Bounded: keep the newest 2,000 executions.
        let list = records.values.sorted { $0.startedAt < $1.startedAt }.suffix(2000)
        if list.count < records.count { records = Dictionary(uniqueKeysWithValues: list.map { ($0.executionId, $0) }) }
        try? AgentCoding.encoder().encode(Array(list)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Serializes generation on on-device models: one GPU, several conversations. Cloud providers run in parallel.
actor GenerationLane {
    private var busy = false
    /// Returns false when the waiting task was cancelled.
    func acquire() async -> Bool {
        while busy {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
        busy = true
        return true
    }
    func release() { busy = false }
}
