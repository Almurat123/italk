import Foundation

// MARK: - Remote computers (the person's own Mac / Windows / Linux machines act as Agent nodes)
//
// The computer owns its models, tools, files and tasks. The phone pairs with it, relays prompts and approvals, and shows
// what the computer really reports. Nothing here is ever simulated: if the computer is asleep or unreachable the state says so.

public enum RemoteOS: String, Codable, Sendable { case mac, windows, linux, other }

public enum RemoteConnectionState: Codable, Sendable, Equatable {
    case disconnected
    case connecting
    /// Transport is up; the signed challenge is being verified.
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    /// Not reachable since `since` (asleep, off, left the network). Tasks may still be running on the computer.
    case unreachable(since: Date)
    /// The computer removed this phone (or the phone was revoked). Pair again to reconnect.
    case revoked
    case failed(String)

    public var isOnline: Bool { if case .connected = self { true } else { false } }
}

public struct RemoteModelInfo: Identifiable, Codable, Sendable, Equatable {
    /// The runtime is reported by the paired computer; unknown older values decode as `.italk`.
    public enum Runtime: String, Codable, Sendable {
        case italk, local
        public init(from decoder: Decoder) throws { self = (try? Self(rawValue: decoder.singleValueContainer().decode(String.self))) ?? .italk }
    }
    public var id: String
    public var name: String
    public var runtime: Runtime
    /// An agent backend runs multi-step tasks with its own tools on the computer; otherwise it is a plain model.
    public var isAgent: Bool
    public var contextWindow: Int?
    public var supportsImages: Bool
    public var supportsTools: Bool
    public var supportsReasoning: Bool
    public init(id: String, name: String, runtime: Runtime, isAgent: Bool, contextWindow: Int? = nil, supportsImages: Bool = false,
                supportsTools: Bool = false, supportsReasoning: Bool = false) {
        self.id = id; self.name = name; self.runtime = runtime; self.isAgent = isAgent; self.contextWindow = contextWindow
        self.supportsImages = supportsImages; self.supportsTools = supportsTools; self.supportsReasoning = supportsReasoning
    }
}

public enum RemoteTaskState: String, Codable, Sendable {
    case queued, running, awaitingApproval, completed, failed, cancelled
    /// The computer stopped reporting and the outcome is not known. Never shown as finished.
    case lost
    public var isFinished: Bool { [.completed, .failed, .cancelled].contains(self) }
}

public struct RemoteApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var summary: String
    public var risk: ToolRisk
    public var expiresAt: Date
    public init(id: String, summary: String, risk: ToolRisk, expiresAt: Date) { self.id = id; self.summary = summary; self.risk = risk; self.expiresAt = expiresAt }
}

public struct RemoteTaskInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var title: String
    public var modelId: String?
    public var state: RemoteTaskState
    /// nil = indeterminate. Only the computer's real report, never an estimate by the phone.
    public var progress: Double?
    public var summary: String
    public var startedAt: Date
    public var updatedAt: Date
    /// Highest event sequence the phone has received; replay continues after it on reconnect.
    public var lastSequence: Int
    public var pendingApproval: RemoteApprovalRequest?
    public init(id: String, deviceId: String, title: String, modelId: String?, state: RemoteTaskState, progress: Double?, summary: String,
                startedAt: Date, updatedAt: Date, lastSequence: Int, pendingApproval: RemoteApprovalRequest? = nil) {
        self.id = id; self.deviceId = deviceId; self.title = title; self.modelId = modelId; self.state = state; self.progress = progress
        self.summary = summary; self.startedAt = startedAt; self.updatedAt = updatedAt; self.lastSequence = lastSequence
        self.pendingApproval = pendingApproval
    }
}

public struct RemoteDeviceInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var os: RemoteOS
    public var state: RemoteConnectionState
    public var pairedAt: Date
    public var lastSeen: Date?
    /// Short identity fingerprint to compare with the one shown on the computer ("A1B2-C3D4-E5F6").
    public var fingerprint: String
    public var models: [RemoteModelInfo]
    public var tasks: [RemoteTaskInfo]
    /// Skills/tools this computer offers in addition to the phone's own.
    public var skillIds: [String]
    public var agentVersion: String?
    public init(id: String, name: String, os: RemoteOS, state: RemoteConnectionState, pairedAt: Date, lastSeen: Date?, fingerprint: String,
                models: [RemoteModelInfo], tasks: [RemoteTaskInfo], skillIds: [String], agentVersion: String? = nil) {
        self.id = id; self.name = name; self.os = os; self.state = state; self.pairedAt = pairedAt; self.lastSeen = lastSeen
        self.fingerprint = fingerprint; self.models = models; self.tasks = tasks; self.skillIds = skillIds; self.agentVersion = agentVersion
    }
}

public enum PairingFailure: String, Codable, Sendable {
    case invalidCode, expired, unreachable, rejectedByComputer, identityMismatch, protocolMismatch, notSupportedInThisBuild, cancelled
    public var message: String {
        switch self {
        case .invalidCode: "二维码无效，请在电脑上重新生成。"
        case .expired: "二维码已过期，请在电脑上重新生成。"
        case .unreachable: "找不到这台电脑。请确认电脑已开机、未休眠并与手机在同一网络，且在“设置 → 隐私与安全性 → 本地网络”中允许了 iTalk。"
        case .rejectedByComputer: "电脑拒绝了这次配对。"
        case .identityMismatch: "电脑的身份与二维码不一致，已停止（可能连到了别的设备）。"
        case .protocolMismatch: "电脑端版本与 App 不兼容，请更新电脑端。"
        case .notSupportedInThisBuild: "这个版本尚未启用远程电脑功能。"
        case .cancelled: "已取消配对。"
        }
    }
}

public enum PairingState: Codable, Sendable, Equatable {
    case idle
    case connecting
    /// Verifying the computer's identity and our one-time secret.
    case verifying
    /// Waiting for the person to approve this phone on the computer.
    case awaitingApprovalOnComputer(fingerprint: String)
    case paired(deviceId: String)
    case failed(PairingFailure)
}
