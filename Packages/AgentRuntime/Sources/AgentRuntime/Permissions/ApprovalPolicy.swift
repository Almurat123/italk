import Foundation
import CryptoKit

// Codex-style approvals, adapted to a phone.
//
// Every tool call is classified by what it does (`ToolRisk`: read / modify / external / sensitive). The device that EXECUTES the
// tool decides, at execution time, whether it may run: automatically (reads, low-risk actions), under a standing grant the
// person gave earlier (once / this session / this conversation / always, bounded by the tool's risk), or only after a fresh
// approval of these exact arguments. Anything proposed after the run read untrusted content (a web page, a file, the clipboard,
// an image) is never covered by a grant and always asks again: content the person did not write cannot spend their approvals.
// Every decision and result is appended to an audit log that holds digests, never the arguments themselves.

public struct ApprovalGrant: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var toolName: String
    public var scope: ApprovalScope
    /// Set for `.conversation` grants.
    public var conversationId: UUID?
    /// When set, only these exact arguments are covered (a grant for one specific action); nil covers any arguments.
    public var argumentDigest: String?
    public var createdAt: Date
    /// App launch the grant belongs to (`.session` grants die with it).
    public var sessionId: UUID?
    /// Plain-language description for the review screen ("日历：创建日程").
    public var summary: String
    public init(id: UUID = UUID(), toolName: String, scope: ApprovalScope, conversationId: UUID? = nil, argumentDigest: String? = nil,
                createdAt: Date = .now, sessionId: UUID? = nil, summary: String) {
        self.id = id; self.toolName = toolName; self.scope = scope; self.conversationId = conversationId; self.argumentDigest = argumentDigest
        self.createdAt = createdAt; self.sessionId = sessionId; self.summary = summary
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    public enum Basis: Sendable, Equatable { case readOnly, lowRisk, grant(UUID) }
    case allow(Basis)
    /// A fresh approval of these exact arguments is required. `offered` are the scopes the person may choose (always includes `.once`).
    case ask(offered: [ApprovalScope], tainted: Bool)
    case deny(code: String, message: String)
}

public struct AuditRecord: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case autoAllowed, grantAllowed, userApproved, userDeclined, expired
        case blockedByPermission, blockedBySkillSwitch, executed, failed, outcomeUnknown
    }
    public var time: Date
    public var runId: UUID
    public var conversationId: UUID
    public var tool: String
    public var risk: ToolRisk
    public var outcome: Outcome
    public var scope: ApprovalScope?
    public var grantId: UUID?
    /// The run had read untrusted content when this was proposed.
    public var tainted: Bool
    /// First 12 hex characters of SHA-256 over the canonical arguments. The arguments themselves are never stored.
    public var argumentDigest: String
    public init(time: Date = .now, runId: UUID, conversationId: UUID, tool: String, risk: ToolRisk, outcome: Outcome, scope: ApprovalScope? = nil,
                grantId: UUID? = nil, tainted: Bool, argumentDigest: String) {
        self.time = time; self.runId = runId; self.conversationId = conversationId; self.tool = tool; self.risk = risk; self.outcome = outcome
        self.scope = scope; self.grantId = grantId; self.tainted = tainted; self.argumentDigest = argumentDigest
    }
}

public extension ToolRiskTable {
    /// Capabilities whose tool results come from content the person did not write. Once a run has read any of it, the run is
    /// "tainted": nothing it proposes afterwards is covered by a standing grant.
    static let untrustedOutput: Set<Capability> = [.web, .files, .documents, .clipboard, .vision, .photos, .audio, .communication, .thirdPartySkills]

    /// The widest approval the person may give for a tool of this risk.
    static func maxScope(for risk: ToolRisk) -> ApprovalScope {
        switch risk {
        case .read: .always
        case .modify: .always
        case .external: .session
        case .sensitive: .once
        }
    }
}

public actor ApprovalPolicy {
    public let sessionId = UUID()
    private var granted: [ApprovalGrant] = []
    private let storeURL: URL?
    private let auditURL: URL?
    private var auditCount = 0
    private static let auditLimit = 4000

    /// `storeURL`: where `.always` and `.conversation` grants persist (nil = memory only). `auditURL`: JSON Lines audit log.
    public init(storeURL: URL? = nil, auditURL: URL? = nil) {
        self.storeURL = storeURL; self.auditURL = auditURL
        if let storeURL, let data = try? Data(contentsOf: storeURL), let list = try? AgentCoding.decoder().decode([ApprovalGrant].self, from: data) { granted = list }
    }

    public static func digest(_ arguments: JSONValue) -> String {
        SHA256.hash(data: Data(arguments.compactString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Decisions

    public func decide(spec: ToolSpec, arguments: JSONValue, conversationId: UUID, tainted: Bool, now: Date = .now) -> ApprovalDecision {
        let risk = spec.risk
        switch spec.permission {
        case .restricted: return .deny(code: "restricted", message: "此操作不能自动执行")
        case .readOnly: return .allow(.readOnly)
        case .lowRiskAction:
            // Opening a compose sheet, playing music, a flashlight: no approval. Unless untrusted content is driving a call that
            // reaches outside iTalk, which must be a decision of the person.
            if tainted, risk == .external || risk == .sensitive { return .ask(offered: [.once], tainted: true) }
            return .allow(.lowRisk)
        case .confirmBeforeAction:
            if tainted { return .ask(offered: [.once], tainted: true) }
            if risk != .sensitive, let g = match(spec: spec, arguments: arguments, conversationId: conversationId, now: now) { return .allow(.grant(g.id)) }
            return .ask(offered: Self.offered(for: risk), tainted: false)
        }
    }

    /// `.once` always; wider choices as far as the tool's risk allows.
    public static func offered(for risk: ToolRisk) -> [ApprovalScope] {
        switch ToolRiskTable.maxScope(for: risk) {
        case .always: [.once, .conversation, .always]
        case .conversation: [.once, .conversation]
        case .session: [.once, .session]
        case .once: [.once]
        }
    }

    private func match(spec: ToolSpec, arguments: JSONValue, conversationId: UUID, now: Date) -> ApprovalGrant? {
        let digest = Self.digest(arguments)
        return granted.first { g in
            guard g.toolName == spec.name else { return false }
            if let d = g.argumentDigest, d != digest { return false }
            switch g.scope {
            case .once: return false
            case .session: return g.sessionId == sessionId
            case .conversation: return g.conversationId == conversationId
            case .always: return true
            }
        }
    }

    // MARK: Grants

    /// Records the person's choice. Returns nil for `.once` (nothing to remember) or when the scope exceeds what the tool's risk allows.
    @discardableResult
    public func grant(spec: ToolSpec, arguments: JSONValue, scope: ApprovalScope, conversationId: UUID, summary: String, exactArguments: Bool = false,
                      now: Date = .now) -> ApprovalGrant? {
        guard scope != .once, scope <= ToolRiskTable.maxScope(for: spec.risk), spec.permission == .confirmBeforeAction, spec.risk != .sensitive else { return nil }
        // Replace an earlier grant for the same tool and place so the list stays small and revocation is unambiguous.
        granted.removeAll { $0.toolName == spec.name && $0.scope == scope && $0.conversationId == (scope == .conversation ? conversationId : nil) && $0.sessionId == (scope == .session ? sessionId : nil) }
        let g = ApprovalGrant(toolName: spec.name, scope: scope, conversationId: scope == .conversation ? conversationId : nil,
                              argumentDigest: exactArguments ? Self.digest(arguments) : nil, createdAt: now,
                              sessionId: scope == .session ? sessionId : nil, summary: summary)
        granted.append(g)
        save()
        return g
    }

    public func grants() -> [ApprovalGrant] { granted.filter { $0.scope != .session || $0.sessionId == sessionId } }
    public func grant(for toolName: String) -> ApprovalGrant? { grants().filter { $0.toolName == toolName }.max { $0.scope < $1.scope } }
    public func revoke(_ id: UUID) { granted.removeAll { $0.id == id }; save() }
    public func revokeAll() { granted.removeAll(); save() }
    public func revoke(tool: String) { granted.removeAll { $0.toolName == tool }; save() }
    /// A deleted conversation takes its grants with it.
    public func forget(conversation id: UUID) { granted.removeAll { $0.conversationId == id }; save() }

    private func save() {
        guard let storeURL else { return }
        let persistent = granted.filter { $0.scope == .always || $0.scope == .conversation }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? AgentCoding.encoder().encode(persistent) {
            #if os(iOS)
            try? data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: storeURL, options: .atomic)
            #endif
        }
    }

    // MARK: Audit

    public func log(_ record: AuditRecord) {
        guard let auditURL else { return }
        guard var line = try? AgentCoding.encoder().encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: auditURL) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
        else { try? line.write(to: auditURL, options: .atomic) }
        auditCount += 1
        if auditCount % 200 == 0 { trimAudit() }
    }

    public func recentAudit(limit: Int = 100) -> [AuditRecord] {
        guard let auditURL, let text = try? String(contentsOf: auditURL, encoding: .utf8) else { return [] }
        let decoder = AgentCoding.decoder()
        return text.split(separator: "\n").suffix(limit).compactMap { try? decoder.decode(AuditRecord.self, from: Data($0.utf8)) }.reversed()
    }

    public func clearAudit() { if let auditURL { try? FileManager.default.removeItem(at: auditURL) }; auditCount = 0 }

    private func trimAudit() {
        guard let auditURL, let text = try? String(contentsOf: auditURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.auditLimit else { return }
        try? (lines.suffix(Self.auditLimit / 2).joined(separator: "\n") + "\n").write(to: auditURL, atomically: true, encoding: .utf8)
    }
}
