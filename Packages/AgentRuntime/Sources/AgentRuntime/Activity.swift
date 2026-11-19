import Foundation

/// A visible step of a run, emitted as events so the UI can show skills, tools, approvals and failures as they happen.
public struct ToolActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case skill, tool, approval, web }
    public enum State: String, Codable, Sendable { case running, succeeded, failed, needsPermission, awaitingApproval, declined, cancelled }
    public var callId: String
    public var name: String
    public var kind: Kind
    public var state: State
    public var title: String
    public var detail: String
    public var summary: String
    public var facts: [[String]]                // [label, value]
    public var sources: [UIComponent.SearchHit]
    public var recovery: PermissionRecovery
    public var permission: String?
    public var symbol: String
    /// What the tool really does, from its declared capability and side effect (companion signals). nil for steps recorded without it.
    public var operation: CompanionOperation? = nil

    public init(callId: String, name: String, kind: Kind, state: State, title: String, detail: String, summary: String, facts: [[String]],
                sources: [UIComponent.SearchHit], recovery: PermissionRecovery, permission: String?, symbol: String, operation: CompanionOperation? = nil) {
        self.callId = callId; self.name = name; self.kind = kind; self.state = state; self.title = title; self.detail = detail
        self.summary = summary; self.facts = facts; self.sources = sources; self.recovery = recovery; self.permission = permission
        self.symbol = symbol; self.operation = operation
    }
}

public extension Capability {
    var symbol: String {
        switch self {
        case .calendar: "calendar"; case .reminders: "checklist"; case .alarms: "alarm"; case .notifications: "bell"; case .health: "heart.text.square"
        case .watch: "applewatch"; case .maps: "map"; case .location: "location"; case .weather: "cloud.sun"; case .contacts: "person.crop.circle"
        case .communication: "message"; case .photos: "photo"; case .camera: "camera"; case .vision: "eye"; case .files: "folder"; case .documents: "doc.richtext"
        case .audio: "waveform"; case .media: "music.note"; case .home: "house"; case .sensors: "figure.walk"; case .device: "iphone"; case .bluetooth: "dot.radiowaves.left.and.right"
        case .nfc: "wave.3.right"; case .clipboard: "doc.on.clipboard"; case .apps: "arrow.up.forward.app"; case .shortcuts: "square.stack.3d.up"; case .thirdPartySkills: "puzzlepiece.extension"
        case .web: "globe"; case .translation: "character.bubble"; case .memory: "brain"; case .language: "text.magnifyingglass"; case .spotlight: "magnifyingglass"
        default: "gearshape"
        }
    }
}

public extension ToolSpec {
    /// Short human title for activity rows ("查询日程"), from the first clause of the description.
    var activityTitle: String {
        let cut = description.firstIndex { "（(，,。；;".contains($0) } ?? description.endIndex
        return String(description[description.startIndex..<cut]).prefix(16).description
    }
}

enum ActivityText {
    /// One line describing the arguments: values only, long ones clipped.
    static func detail(_ args: JSONValue) -> String {
        guard let o = args.object else { return "" }
        let parts = o.sorted { $0.key < $1.key }.compactMap { _, v -> String? in
            switch v {
            case .string(let s): return s.isEmpty ? nil : String(s.prefix(36))
            case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
            case .bool(let b): return b ? "是" : "否"
            default: return nil
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Key figures for native visualization: tool-provided facts, else the first scalar fields of the result.
    static func facts(_ out: ToolOutput) -> [[String]] {
        if let f = out.facts, !f.isEmpty { return f.prefix(6).map { [$0.label, $0.value] } }
        guard let o = out.value.object else { return [] }
        let skip: Set<String> = ["note", "source", "verified", "ok", "id", "text", "more", "pageId"]
        var rows: [[String]] = []
        for (k, v) in o.sorted(by: { $0.key < $1.key }) where !skip.contains(k) {
            switch v {
            case .string(let s) where s.count <= 30: rows.append([k, s])
            case .number(let n): rows.append([k, n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)])
            default: break
            }
            if rows.count >= 4 { break }
        }
        return rows
    }
}

/// Phrases that say an action was completed. A final answer that claims one without any tool having run is not trusted.
public enum ActionClaims {
    public static func claimsCompletion(_ text: String) -> Bool {
        text.range(of: "已(经)?(成功)?(为你|帮你|给你)?(设置|设定|创建|新建|添加|删除|取消|发送|保存|打开|播放|拨打|安排|记录|写入|预约|订|开启|关闭)", options: .regularExpression) != nil
            || text.range(of: "(设置|创建|添加|保存|发送|安排)(好|成功|完成)了", options: .regularExpression) != nil
    }
}
