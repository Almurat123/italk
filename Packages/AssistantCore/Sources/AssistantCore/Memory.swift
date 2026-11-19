import Foundation

public struct MemoryRevision: Codable, Sendable, Equatable {
    public var content: String
    public var changedAt: Date
    public var reason: String
}

public struct MemoryRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var content: String
    public var sensitive: Bool
    public var sourceTurn: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var history: [MemoryRevision]

    public init(content: String, sensitive: Bool, sourceTurn: UUID, now: Date = .now) {
        id = UUID(); self.content = content; self.sensitive = sensitive; self.sourceTurn = sourceTurn
        createdAt = now; updatedAt = now; revision = 1; history = []
    }

    public mutating func edit(_ text: String, expectedRevision: Int, now: Date = .now) throws {
        guard revision == expectedRevision else { throw MemoryError.conflict }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else { throw MemoryError.invalid }
        history.append(.init(content: content, changedAt: now, reason: "user_edit"))
        content = text; revision += 1; updatedAt = now
    }
}

public enum MemoryError: Error { case conflict, invalid }

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let question: String
    public let answer: String
    public let date: Date
    public init(id: UUID, question: String, answer: String) {
        self.id = id; self.question = question; self.answer = answer; date = .now
    }
}

public struct ConsolidationProposal: Identifiable, Sendable {
    public let id: UUID
    public let content: String
    public let sources: [UUID]
    public init(content: String, sources: [UUID]) {
        id = UUID(); self.content = content; self.sources = sources
    }
}

public enum MemoryReview {
    public static func candidates(from entries: [HistoryEntry], existing: [MemoryRecord], limit: Int = 50) -> [ConsolidationProposal] {
        let known = Set(existing.map { normalize($0.content) })
        var seen = known
        return entries.suffix(max(0, min(limit, 50))).compactMap { entry in
            let explicit = entry.question.hasPrefix("记住")
            guard explicit || ["我喜欢", "我更喜欢", "以后请", "以后回答", "我希望"].contains(where: { entry.question.hasPrefix($0) }) else { return nil }
            let content = (explicit ? String(entry.question.dropFirst(2)) : entry.question).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard !content.isEmpty, !MandarinRouter.isPotentiallySensitive(content), seen.insert(normalize(content)).inserted else { return nil }
            return .init(content: content, sources: [entry.id])
        }
    }
    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
