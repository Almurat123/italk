import Foundation

// MARK: - Shared conversation contract (Codex renders these; Claude owns storage)

/// One structured piece of a message. Messages are never stored as a single flat string.
public enum MessagePart: Codable, Sendable, Equatable {
    case text(String)
    case image(attachmentId: UUID)
    /// Record that a tool ran (or was proposed), kept for audit and for "already done" checks after edits.
    case tool(callId: String, name: String, summary: String, status: String)
    case card(componentId: String)
}

public enum MessageRole: String, Codable, Sendable { case user, assistant, system, tool }

public enum MessageStatus: String, Codable, Sendable {
    /// Still streaming / unstable (e.g. provisional ASR or partial generation). Never treated as final.
    case pending
    case final
    case failed
    case cancelled
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationId: UUID
    /// Strictly increasing per conversation. Order is by `seq`, never by timestamp.
    public var seq: Int
    public var role: MessageRole
    public var parts: [MessagePart]
    public var status: MessageStatus
    public var createdAt: Date
    public var runId: UUID?
    public var modelId: String?
    public var inputMode: String?          // "voice" | "text"
    public var text: String { parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n") }
    public var imageIds: [UUID] { parts.compactMap { if case .image(let id) = $0 { id } else { nil } } }
    public init(id: UUID = UUID(), conversationId: UUID, seq: Int = 0, role: MessageRole, parts: [MessagePart], status: MessageStatus = .final,
                createdAt: Date = .now, runId: UUID? = nil, modelId: String? = nil, inputMode: String? = nil) {
        self.id = id; self.conversationId = conversationId; self.seq = seq; self.role = role; self.parts = parts; self.status = status
        self.createdAt = createdAt; self.runId = runId; self.modelId = modelId; self.inputMode = inputMode
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public enum TitleSource: String, Codable, Sendable { case automatic, user }
    public var id: UUID
    public var title: String
    public var titleSource: TitleSource
    public var createdAt: Date
    public var lastActivityAt: Date
    public var pinned: Bool
    public var archived: Bool
    /// Soft delete: hidden everywhere, restorable until purged (`ConversationStore.purgeAfter`).
    public var deletedAt: Date?
    public var lastModelId: String?
    public var messageCount: Int
    public var preview: String
    public var hasUnfinishedRun: Bool
}

public struct AttachmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationId: UUID
    public var kind: String                 // "image"
    public var relativePath: String         // under the attachments root
    public var mimeType: String
    public var bytes: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var sha256: String
    public var createdAt: Date
}

/// Sidebar sections, in display order.
public enum ConversationGroup: String, Codable, Sendable, CaseIterable {
    case pinned, today, yesterday, previous7Days, previous30Days, older
    public var title: String {
        switch self { case .pinned: "置顶"; case .today: "今天"; case .yesterday: "昨天"; case .previous7Days: "7 天内"; case .previous30Days: "30 天内"; case .older: "更早" }
    }
    public static func group(for c: Conversation, now: Date, calendar: Calendar = .current) -> ConversationGroup {
        if c.pinned { return .pinned }
        if calendar.isDate(c.lastActivityAt, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(c.lastActivityAt, inSameDayAs: y) { return .yesterday }
        let days = now.timeIntervalSince(c.lastActivityAt) / 86_400
        return days <= 7 ? .previous7Days : days <= 30 ? .previous30Days : .older
    }
}

public enum ConversationFilter: String, Codable, Sendable { case active, archived, deleted }

public struct ConversationSearchHit: Codable, Sendable, Equatable {
    public var conversation: Conversation
    public var messageId: UUID?
    public var snippet: String
}

/// Automatic title from the first user message: deterministic, no model call, no hallucination.
public enum ConversationTitler {
    public static func title(from text: String, maxLength: Int = 18) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["请问", "帮我", "你好，", "你好", "嗨，", "我想问一下", "我想问"] where t.hasPrefix(p) && t.count > p.count + 2 { t = String(t.dropFirst(p.count)) }
        t = t.replacingOccurrences(of: "\n", with: " ")
        let cut = t.firstIndex(where: { "。？！?!\n".contains($0) }).map { String(t[..<$0]) } ?? t
        let core = cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        if core.isEmpty { return "新对话" }
        return core.count > maxLength ? String(core.prefix(maxLength)) + "…" : core
    }
}
