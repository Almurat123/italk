import Foundation

// MARK: - Skill registry contract (UI-facing, additive only)
//
// One global registry serves every model (local, cloud, remote). The UI shows it, lets the person switch a skill off, and
// shows the real iOS authorization state next to it. Reading a skill's documentation never needs any of this.

/// Codex-style action classes, adapted to a phone. `discover` (reading skills) is always free and never appears on a tool.
public enum ToolRisk: String, Codable, Sendable, CaseIterable {
    /// Looks at information (calendar, health, web, location…).
    case read
    /// Changes data inside the person's own apps or iTalk (create event, set alarm, write a file).
    case modify
    /// Acts outside iTalk (compose a message, open another app, run a shortcut, control a home accessory, a remote computer).
    case external
    /// Sensitive or destructive (delete, unlock, call, anything that is hard to undo).
    case sensitive

    public var title: String {
        switch self { case .read: "读取"; case .modify: "修改"; case .external: "对外操作"; case .sensitive: "敏感操作" }
    }
}

/// How long an approval lasts. `once` is the default for anything above `read`.
public enum ApprovalScope: String, Codable, Sendable, CaseIterable, Comparable {
    case once
    /// Until the app is closed or the time limit passes.
    case session
    /// For the rest of this conversation.
    case conversation
    /// A standing rule the person can review and revoke (never offered for `sensitive` tools).
    case always

    private var rank: Int { switch self { case .once: 0; case .session: 1; case .conversation: 2; case .always: 3 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    public var title: String { switch self { case .once: "仅这一次"; case .session: "本次使用期间"; case .conversation: "本次对话"; case .always: "以后总是允许" } }
}

public struct SkillToolInfo: Identifiable, Codable, Sendable, Equatable {
    /// Tool name as the model calls it, e.g. `calendar_create_event`.
    public var id: String
    public var title: String
    public var summary: String
    public var risk: ToolRisk
    /// An approval card appears before it runs, unless a standing grant covers it.
    public var asksBeforeRunning: Bool
    /// Highest scope the person may grant for this tool.
    public var maxScope: ApprovalScope
    public var dataClass: DataClass
    /// A grant that currently covers this tool (nil = ask).
    public var standingGrant: ApprovalScope?
    public init(id: String, title: String, summary: String, risk: ToolRisk, asksBeforeRunning: Bool, maxScope: ApprovalScope,
                dataClass: DataClass, standingGrant: ApprovalScope? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.risk = risk; self.asksBeforeRunning = asksBeforeRunning
        self.maxScope = maxScope; self.dataClass = dataClass; self.standingGrant = standingGrant
    }
}

/// The iOS authorization state a skill needs (worst case across its tools), in the vocabulary the UI renders.
public enum SkillPermission: Codable, Sendable, Equatable {
    case notRequired
    case granted
    /// Partial access (selected photos, write-only calendar…).
    case limited
    /// iOS has not asked yet; it will the first time the skill is used (or when the person taps "request").
    case notDetermined
    case denied
    /// Blocked by Screen Time / device management; iTalk cannot change it.
    case restricted
    /// This device, OS or build cannot do it (reason in the associated value).
    case unavailable(String)
    /// HealthKit: iOS never reveals whether read access was granted. Results of "no data" may mean "not allowed".
    case unknownByDesign

    public var isUsable: Bool {
        switch self { case .notRequired, .granted, .limited, .unknownByDesign, .notDetermined: true; default: false }
    }
}

public enum SkillSource: Codable, Sendable, Equatable {
    case builtIn
    /// Provided by a paired computer (device id).
    case remote(String)
    /// Installed by the person from a file, a link or pasted text (see `SkillTrust`).
    case installed(SkillTrust)
}

public struct SkillInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// One line, the same text every model sees in the skill catalog.
    public var summary: String
    /// SF Symbol name.
    public var symbol: String
    /// iTalk privacy switches this skill depends on (see `Capability.label`).
    public var capabilities: [Capability]
    public var permission: SkillPermission
    /// Plain-language state + recovery ("设置 › iTalk › 日历 中开启").
    public var permissionDetail: String
    /// Off = the skill is hidden from models and its tools refuse to run.
    public var enabled: Bool
    public var tools: [SkillToolInfo]
    /// What iOS does not let any app do in this area (shown honestly).
    public var limitations: String
    public var source: SkillSource
    /// Capabilities whose iTalk privacy switch (Settings › 隐私与权限) is off; the skill cannot run until they are turned back on.
    public var blockedBy: [Capability]
    public var version: String?
    public var category: SkillCategory?
    public var author: String?
    /// For installed skills that cannot run (missing dependency, damaged files): plain-language reason. nil = fine.
    public var issue: String?
    /// Web hosts an installed skill may call (what the person approved).
    public var hosts: [String]
    /// Installed skills can be removed; built-in ones cannot.
    public var canRemove: Bool { if case .installed = source { true } else { false } }
    public init(id: String, name: String, summary: String, symbol: String, capabilities: [Capability], permission: SkillPermission,
                permissionDetail: String, enabled: Bool, tools: [SkillToolInfo], limitations: String, source: SkillSource = .builtIn,
                blockedBy: [Capability] = [], version: String? = nil, category: SkillCategory? = nil, author: String? = nil, issue: String? = nil, hosts: [String] = []) {
        self.id = id; self.name = name; self.summary = summary; self.symbol = symbol; self.capabilities = capabilities
        self.permission = permission; self.permissionDetail = permissionDetail; self.enabled = enabled; self.tools = tools
        self.limitations = limitations; self.source = source; self.blockedBy = blockedBy
        self.version = version; self.category = category; self.author = author; self.issue = issue; self.hosts = hosts
    }
}


// MARK: - Risk classification (declared once here, enforced by whichever device executes the tool)

public enum ToolRiskTable {
    /// Tools whose effect is hard to undo or reaches other people: always asked about, never covered by a standing grant.
    public static let sensitive: Set<String> = ["phone_call", "calendar_delete_event", "files_delete", "home_control_secure", "home_run_scene"]
    /// Capabilities that act outside iTalk and the person's own data (other apps, other people, accessories, other computers).
    public static let external: Set<Capability> = [.communication, .apps, .shortcuts, .home, .nfc, .bluetooth, .thirdPartySkills]
}

public extension ToolSpec {
    /// Codex-style action class: read / modify / external / sensitive.
    var risk: ToolRisk {
        if permission == .restricted || ToolRiskTable.sensitive.contains(name) { return .sensitive }
        switch permission {
        case .readOnly: return .read
        case .lowRiskAction, .confirmBeforeAction: return ToolRiskTable.external.contains(capability) ? .external : .modify
        case .restricted: return .sensitive
        }
    }
    /// A short human title: the first clause of the description.
    var shortTitle: String {
        let stops: Set<Character> = ["，", "。", "（", "(", ";", "；", ":", "：", ",", "、"]
        let head = description.prefix { !stops.contains($0) }
        return String(head.prefix(22))
    }
}
