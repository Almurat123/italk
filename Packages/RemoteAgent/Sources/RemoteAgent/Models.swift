import Foundation
import AgentRuntime

/// A paired computer as the phone stores it. Nothing secret: the phone's private key lives in the Keychain, and the computer's public key
/// and certificate pin are public values.
public struct AgentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var publicKey: Data
    public var certificatePin: String
    /// `host:port`
    public var endpoints: [String]
    /// This phone's id as the computer knows it.
    public var phoneId: String
    public var pairedAt: Date
    public var fingerprint: String { RemoteIdentity.fingerprint(of: publicKey) }
    public init(id: String, name: String, publicKey: Data, certificatePin: String, endpoints: [String], phoneId: String, pairedAt: Date) {
        self.id = id; self.name = name; self.publicKey = publicKey; self.certificatePin = certificatePin; self.endpoints = endpoints; self.phoneId = phoneId; self.pairedAt = pairedAt
    }
}

public struct AgentStatus: Codable, Sendable, Equatable {
    public struct Agent: Codable, Sendable, Equatable { public var id: String; public var name: String; public var version: String; public var platform: String; public var fingerprint: String }
    public struct Backend: Codable, Sendable, Equatable, Identifiable {
        public var id: String; public var name: String; public var kind: String; public var available: Bool
        public var detail: String?; public var models: [String]; public var defaultModel: String?; public var approvals: String?
        /// The official models this account may use on this computer (names, context size, abilities).
        public var modelInfo: [CloudModel]?
        public var subscription: CloudSubscription?
        public var cloud: CloudDescription?
    }
    public struct Limits: Codable, Sendable, Equatable { public var maxPermissionMode: String; public var maxConcurrentTasks: Int; public var approvalTimeoutMinutes: Int; public var retentionDays: Int }
    public var agent: Agent
    public var backends: [Backend]
    public var limits: Limits
    public var roots: [String]
    public var home: String
    public var time: Double
}

/// One of iTalk's own models, as the gateway describes it. There is no other kind of model on a paired computer.
public struct CloudModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var developer: String?
    public var contextTokens: Int?
    public var supportsTools: Bool?
    public var supportsReasoning: Bool?
    public var supportsImages: Bool?
    public var usageWeight: Double?
    public init(id: String, name: String? = nil, developer: String? = nil, contextTokens: Int? = nil, supportsTools: Bool? = nil, supportsReasoning: Bool? = nil, supportsImages: Bool? = nil, usageWeight: Double? = nil) {
        self.id = id; self.name = name; self.developer = developer; self.contextTokens = contextTokens; self.supportsTools = supportsTools; self.supportsReasoning = supportsReasoning; self.supportsImages = supportsImages; self.usageWeight = usageWeight
    }
}
public struct CloudSubscription: Codable, Sendable, Equatable { public var status: String; public var tier: String?; public var planName: String? }
/// What the computer stores about its model access: where it points and when it was issued. Never the credential.
public struct CloudDescription: Codable, Sendable, Equatable {
    public var configured: Bool
    public var gateway: String?
    public var issuedAt: Double?
    public var expiresAt: Double?
    public var accountHint: String?
    public var sessionName: String?
}
/// The computer's own check of that access: a real round trip to the gateway.
public struct CloudVerification: Codable, Sendable, Equatable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var subscription: CloudSubscription?
    public var models: [CloudModel]?
    public var latencyMs: Double?
}
public struct CloudState: Codable, Sendable, Equatable { public var cloud: CloudDescription; public var verification: CloudVerification? }

/// What the computer can do for the phone: tools (with risk), skills, and the project's own instruction file for a folder.
public struct AgentCapabilities: Decodable, Sendable, Equatable {
    public struct Tool: Decodable, Sendable, Equatable, Identifiable { public var name: String; public var summary: String; public var risk: String; public var kind: String; public var id: String { name } }
    public struct Skill: Decodable, Sendable, Equatable, Identifiable { public var name: String; public var description: String; public var source: String; public var category: String?; public var id: String { name } }
    public struct Instructions: Decodable, Sendable, Equatable { public var file: String; public var folder: String; public var chars: Int; public var blocked: Bool }
    public var tools: [Tool]
    public var skills: [Skill]
    public var skillIssues: [String]?
    public var instructions: Instructions?
    public var cloud: CloudDescription?
}

public struct RemoteTaskSnapshot: Codable, Sendable, Equatable, Identifiable {
    public struct Failure: Codable, Sendable, Equatable { public var code: String; public var message: String? }
    public var id: String
    public var state: String
    public var backend: String
    public var model: String?
    public var cwd: String?
    public var permissionMode: String
    public var title: String?
    public var continueOf: String?
    public var hasSession: Bool
    public var createdAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var lastSeq: Int
    public var error: Failure?
    public var pendingApprovals: Int
    public var isFinished: Bool { ["completed", "failed", "cancelled"].contains(state) }
}

public struct NewRemoteTask: Encodable, Sendable {
    public struct Turn: Encodable, Sendable { public var role: String; public var text: String; public init(role: String, text: String) { self.role = role; self.text = text } }
    public var backend: String
    public var prompt: String
    public var history: [Turn]?
    public var model: String?
    public var cwd: String?
    public var permissionMode: String?
    public var continueTaskId: String?
    public var title: String?
    public var reasoningEffort: String?
    /// Explicitly selected, non-sensitive facts for this task only; nil sends no personal memory.
    public var sharedMemory: [String]?
    public init(backend: String = "italk", prompt: String, history: [Turn]? = nil, model: String? = nil, cwd: String? = nil, permissionMode: String? = nil, continueTaskId: String? = nil, title: String? = nil, reasoningEffort: String? = nil, sharedMemory: [String]? = nil) {
        self.backend = backend; self.prompt = prompt; self.history = history; self.model = model; self.cwd = cwd; self.permissionMode = permissionMode; self.continueTaskId = continueTaskId; self.title = title; self.reasoningEffort = reasoningEffort; self.sharedMemory = sharedMemory
    }
}

public struct RemoteApproval: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var taskId: String
    public var tool: String
    public var summary: String
    public var risk: String
    public var tainted: Bool
    public var state: String
    public var requestedAt: Double
    public var expiresAt: Double
}

public struct RemoteFolders: Decodable, Sendable, Equatable { public var path: String; public var parent: String?; public var folders: [String] }

public struct RemoteEvent: Sendable, Equatable, Identifiable {
    public var seq: Int
    public var type: String
    public var data: JSONValue
    public var id: Int { seq }
    public var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(type) }
    public func string(_ key: String) -> String? { if case .object(let o) = data, case .string(let s)? = o[key] { return s }; return nil }
    public func number(_ key: String) -> Double? { if case .object(let o) = data, case .number(let n)? = o[key] { return n }; return nil }
    public func bool(_ key: String) -> Bool? { if case .object(let o) = data, case .bool(let b)? = o[key] { return b }; return nil }
    public func strings(_ key: String) -> [String] { if case .object(let o) = data, case .array(let a)? = o[key] { return a.compactMap { if case .string(let s) = $0 { s } else { nil } } }; return [] }
}

public enum RemoteError: Error, LocalizedError, Sendable, Equatable {
    case unreachable
    /// The certificate presented is not the one that was paired: possibly another device on the network.
    case identityMismatch
    case revoked
    case clockSkew
    case http(status: Int, code: String)
    case malformedResponse
    public var errorDescription: String? {
        switch self {
        case .unreachable: "找不到这台电脑。请确认它已开机、未休眠，并与手机在同一网络。"
        case .identityMismatch: "连接到的设备与配对时的电脑不一致，已停止。"
        case .revoked: "这台电脑已取消了对此手机的授权。请重新扫码配对。"
        case .clockSkew: "手机与电脑的时间相差太大，请开启自动设置时间。"
        case .http(_, let code): Self.message(for: code)
        case .malformedResponse: "电脑返回了无法识别的内容。"
        }
    }
    static func message(for code: String) -> String {
        switch code {
        case "backend_not_available": "电脑上的 iTalk 智能体还不可用。"
        case "invalid_gateway", "invalid_token": "模型访问凭证无效，请重新设置这台电脑。"
        case "question_not_found": "这个问题已经结束。"
        case "cwd_not_allowed": "这个文件夹不在电脑允许使用的范围内。"
        case "invalid_arguments": "请求内容无效。"
        case "idempotency_conflict": "同一个任务被提交了不同的内容。"
        case "session_not_ready": "上一项任务还在等待开始，请稍后再继续对话。"
        case "too_many_streams": "同时查看的任务太多。"
        case "approval_expired": "确认请求已过期。"
        case "task_not_found", "approval_not_found": "找不到这个任务。"
        case "rejected_by_computer": "电脑拒绝了这次配对。"
        case "pairing_expired": "二维码已过期，请在电脑上重新生成。"
        case "invalid_proof": "二维码无效，请在电脑上重新生成。"
        default: "电脑返回错误（\(code)）。"
        }
    }
}
