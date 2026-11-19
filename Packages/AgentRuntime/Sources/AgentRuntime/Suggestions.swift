import Foundation

/// A suggestion shown on an empty conversation. Never rendered as a fake message.
public struct PromptSuggestion: Codable, Sendable, Equatable, Identifiable {
    public enum Action: Codable, Sendable, Equatable { case send(String), openConversation(UUID) }
    public enum Kind: String, Codable, Sendable { case unfinishedTask, continueConversation, timeOfDay, starter }
    public var id: String
    public var title: String
    public var action: Action
    public var kind: Kind
    public var score: Double
}

/// Small local ranking (no model, no network): task continuation > recent topics > time of day > generic starters.
/// Uses only titles of conversations already stored with history consent; session-only (sensitive) turns never reach titles.
public enum SuggestionEngine {
    public static let starters = ["用简单的话解释一下什么是通货膨胀", "帮我写一条礼貌的请假消息", "推荐一道二十分钟能做好的晚饭", "帮我想一个周末放松的安排"]

    public static func suggestions(recent: [Conversation], now: Date = .now, calendar: Calendar = .current,
                                   dismissed: Set<String> = [], limit: Int = 3) -> [PromptSuggestion] {
        var out: [PromptSuggestion] = []
        for c in recent where c.hasUnfinishedRun && c.deletedAt == nil && !c.archived {
            out.append(.init(id: "task-\(c.id)", title: "继续未完成的任务：\(c.title)", action: .openConversation(c.id), kind: .unfinishedTask, score: 1.0))
        }
        for c in recent where !c.hasUnfinishedRun && c.deletedAt == nil && !c.archived && c.title != "新对话" {
            let days = now.timeIntervalSince(c.lastActivityAt) / 86_400
            guard days < 3 else { continue }
            out.append(.init(id: "conv-\(c.id)", title: "继续聊：\(c.title)", action: .openConversation(c.id), kind: .continueConversation,
                             score: 0.8 - days * 0.15 + (c.pinned ? 0.1 : 0)))
        }
        let hour = calendar.component(.hour, from: now)
        let timely: String? = switch hour {
        case 5..<10: "帮我列一下今天要做的三件事"
        case 11..<14: "午饭吃什么比较健康又简单？"
        case 18..<23: "帮我回顾一下今天，想想明天的安排"
        default: nil
        }
        if let timely { out.append(.init(id: "time-\(hour / 6)", title: timely, action: .send(timely), kind: .timeOfDay, score: 0.5)) }
        // Starters fill the rest; first-time users see mostly these.
        for (i, s) in starters.enumerated() { out.append(.init(id: "starter-\(i)", title: s, action: .send(s), kind: .starter, score: 0.3 - Double(i) * 0.01)) }

        // Rank, drop dismissed, dedupe by title, and keep variety: at most two "continue" items.
        var seen = Set<String>(), picked: [PromptSuggestion] = [], continues = 0
        for s in out.sorted(by: { $0.score > $1.score }) where !dismissed.contains(s.id) && seen.insert(s.title).inserted {
            if s.kind == .continueConversation || s.kind == .unfinishedTask { guard continues < 2 else { continue }; continues += 1 }
            picked.append(s)
            if picked.count == limit { break }
        }
        return picked
    }
}
