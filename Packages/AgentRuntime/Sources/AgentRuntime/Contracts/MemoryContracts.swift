import Foundation

// MARK: - Personal memory (distinct from transcripts and from temporary context compression)

public enum MemoryKind: String, Codable, Sendable, CaseIterable {
    /// Likes, dislikes, style ("喜欢简短的回答").
    case preference
    /// Stable facts about the person ("在杭州工作").
    case fact
    /// Ongoing situations ("正在准备搬家").
    case context
    /// Standing instructions ("称呼我小明").
    case instruction
    public var title: String {
        switch self { case .preference: "偏好"; case .fact: "个人信息"; case .context: "近期情况"; case .instruction: "长期指令" }
    }
}

public enum MemorySource: Codable, Sendable, Equatable {
    /// Learned from a conversation (id of the source conversation; deleting that conversation does not delete the memory).
    case conversation(UUID)
    /// Written or edited by the person.
    case user
    /// Saved by the agent at the person's explicit request.
    case agent
}

public struct MemoryItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var kind: MemoryKind
    public var source: MemorySource
    public var createdAt: Date
    public var updatedAt: Date
    /// Health or other sensitive content; never sent to cloud models without the separate switch.
    public var sensitive: Bool
    public var pinned: Bool
    /// Increases on every edit (used for conflict resolution when synced).
    public var revision: Int
    /// What this item is about ("residence", "pref:咖啡"). A new statement about the same slot replaces the old one (a correction), instead of adding a second, contradicting item.
    public var slot: String?
    public init(id: UUID = UUID(), text: String, kind: MemoryKind, source: MemorySource, createdAt: Date = .now, updatedAt: Date = .now,
                sensitive: Bool = false, pinned: Bool = false, revision: Int = 1, slot: String? = nil) {
        self.id = id; self.text = text; self.kind = kind; self.source = source; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.sensitive = sensitive; self.pinned = pinned; self.revision = revision; self.slot = slot
    }
}

public struct MemorySettings: Codable, Sendable, Equatable {
    /// Master switch: when off, nothing is read into context and nothing new is learned (stored items are kept until deleted).
    public var enabled: Bool
    /// Let past conversations inform answers (searches conversation history for relevant context).
    public var referenceChatHistory: Bool
    /// Learn new items automatically from conversations (otherwise only on explicit request).
    public var learnAutomatically: Bool
    public init(enabled: Bool = true, referenceChatHistory: Bool = true, learnAutomatically: Bool = true) {
        self.enabled = enabled; self.referenceChatHistory = referenceChatHistory; self.learnAutomatically = learnAutomatically
    }
}

/// State of iCloud sync for the memory screen (nothing is synced unless the person switched it on and iCloud is really usable).
public enum MemorySyncStatus: Sendable, Equatable {
    case off
    /// iCloud cannot be used right now; the reason is plain language ("未登录 iCloud", "另一台设备的加密密钥尚未同步").
    case unavailable(String)
    case syncing
    case synced(Date)
    case offline(String)
}
