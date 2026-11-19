import Foundation

/// Skills are procedural knowledge plus the tools they explain. They never grant permissions: every tool is still checked
/// live (`PermissionGate`) when it runs. Reading a skill never needs authorization.
///
/// Three layers keep context small for every model, local or cloud:
/// 1. The catalog — name + one-line summary of *every* skill — is always in the system prompt.
/// 2. `read_skill` returns a skill's instructions and tool schemas (no side effects, no permission).
/// 3. `load_skill` makes those tools callable in this run. Tool schemas are never preloaded.
public struct Skill: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var instructions: String
    public var toolNames: [String]
    /// What Apple does not expose for this area (stated honestly to the model and in docs).
    public var limitations: String
    /// Whose words the instructions are. Anything but built-in/own text is read like web content: it taints the run (no standing approvals apply) and is fenced in the prompt.
    public var trust: SkillTrust
    public var version: String?
    public var category: SkillCategory?
    public var author: String?
    /// A short form of `instructions` (a few hundred tokens at most) for models with a small window. When the full text is longer than the skill budget of the
    /// window, the short form goes into the prompt and the full text stays one `read_skill` away. nil = the instructions are short enough as they are.
    public var brief: String?
    public init(id: String, name: String, summary: String, instructions: String, toolNames: [String], limitations: String = "",
                trust: SkillTrust = .builtIn, version: String? = nil, category: SkillCategory? = nil, author: String? = nil, brief: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.instructions = instructions
        self.toolNames = toolNames; self.limitations = limitations; self.trust = trust; self.version = version; self.category = category; self.author = author; self.brief = brief
    }
}

/// User-authored local text, separate from the installed package and its trust and permissions.
public struct SkillTextOverride: Codable, Sendable, Equatable {
    public var summary: String
    public var instructions: String
    public init(summary: String, instructions: String) { self.summary = summary; self.instructions = instructions }

    public func applying(to original: Skill) -> Skill {
        var skill = original
        skill.summary = summary
        skill.instructions = instructions
        // A built-in brief describes the original instructions, not the edited version.
        skill.brief = nil
        return skill
    }
}

/// The one global registry shared by every model. No keyword routing, no model-size gating.
public struct SkillCatalog: Sendable {
    public private(set) var skills: [Skill]
    public init(_ skills: [Skill]) { self.skills = skills }

    public func skill(_ id: String) -> Skill? { skills.first { $0.id == id } }
    public func skill(containing tool: String) -> Skill? { skills.first { $0.toolNames.contains(tool) } }
    public mutating func add(_ skill: Skill) { skills.removeAll { $0.id == skill.id }; skills.append(skill) }
    public mutating func add(_ more: [Skill]) { for s in more { add(s) } }
    public mutating func remove(_ id: String) { skills.removeAll { $0.id == id } }

    /// Layer 1: the complete catalog, one line each.
    public func catalogText() -> String {
        skills.map { "- \($0.id)（\($0.name)）：\($0.summary)" }.joined(separator: "\n")
    }

    /// Layer 2: everything a model needs to decide whether and how to use a skill. `briefIfLonger`: when the full instructions take more than this many
    /// tokens and the skill has a short form, the short form is returned (with a note), so reading a skill can never use up a small window.
    public func readText(_ skill: Skill, tools: ToolRegistry, statuses: [String: String] = [:], briefIfLonger: Int? = nil) -> String {
        var body = skill.instructions
        if let limit = briefIfLonger, let brief = skill.brief, !brief.isEmpty, TokenEstimator.tokens(body) > limit {
            body = brief + "\n（完整说明较长，当前模型的上下文放不下，这里给出的是简要说明。）"
        }
        var out = "技能 \(skill.id)（\(skill.name)）\n\(body)"
        let specs = skill.toolNames.compactMap { tools.tool(named: $0)?.spec }
        if !specs.isEmpty {
            out += "\n\n工具：\n" + specs.map { s in
                "- " + s.schemaText + (statuses[s.name].map { "\n    当前状态：\($0)" } ?? "")
            }.joined(separator: "\n")
        }
        if !skill.limitations.isEmpty { out += "\n\n系统限制：\(skill.limitations)" }
        return out
    }
}

public extension SkillCatalog {
    /// Runtime-portable skills. The iPhone app adds the Apple capability skills (`AppleSkills`) and web skills.
    static let standard = SkillCatalog([
        Skill(id: "core", name: "时间与计算", summary: "当前日期时间、时区换算、精确算术",
              instructions: "需要精确时间时调用 get_current_datetime；任何算术都用 calculate，不要心算。",
              toolNames: ["get_current_datetime", "calculate"]),
        Skill(id: "reminders", name: "提醒事项", summary: "创建提醒事项",
              instructions: "创建提醒前确认标题和时间；时间不明确时先询问，不要猜测。创建会向用户请求确认。",
              toolNames: ["create_reminder"])
    ])
}
