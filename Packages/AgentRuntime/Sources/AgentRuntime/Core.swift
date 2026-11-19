import Foundation

/// Wire format is camelCase JSON, ISO-8601 dates. Dictionary keys are never rewritten.
public enum AgentCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
    public var compactString: String {
        (try? String(data: AgentCoding.encoder().encode(self), encoding: .utf8)) ?? "null"
    }
}

public enum RunState: String, Codable, Sendable, CaseIterable {
    case created, queued, planning, running, awaitingTool, awaitingApproval, suspended
    case awaitingNetwork, awaitingForeground, resuming, completed, failed, cancelled, expired

    public var isTerminal: Bool { [.completed, .failed, .cancelled, .expired].contains(self) }

    public func canTransition(to next: RunState) -> Bool {
        if self == next { return true }
        switch self {
        case .created: return [.queued, .planning, .running, .cancelled, .failed].contains(next)
        case .queued: return [.planning, .running, .awaitingForeground, .cancelled, .expired].contains(next)
        case .planning: return [.running, .suspended, .resuming, .failed, .cancelled].contains(next)
        case .running: return [.resuming, .awaitingTool, .awaitingApproval, .suspended, .awaitingNetwork, .awaitingForeground, .completed, .failed, .cancelled].contains(next)
        case .awaitingTool: return [.running, .resuming, .awaitingApproval, .suspended, .failed, .cancelled].contains(next)
        case .awaitingApproval: return [.running, .suspended, .expired, .failed, .cancelled].contains(next)
        case .suspended: return [.resuming, .cancelled, .expired, .failed].contains(next)
        case .awaitingNetwork, .awaitingForeground: return [.resuming, .cancelled, .expired, .failed].contains(next)
        case .resuming: return [.running, .planning, .awaitingApproval, .suspended, .completed, .failed, .cancelled, .awaitingNetwork].contains(next)
        case .completed, .failed, .cancelled, .expired: return false
        }
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Seconds from request to first generated token; nil when not measured.
    public var firstTokenLatency: Double?
    public var tokensPerSecond: Double?
    public var providerId: String
    public init(promptTokens: Int = 0, completionTokens: Int = 0, firstTokenLatency: Double? = nil, tokensPerSecond: Double? = nil, providerId: String = "") {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.firstTokenLatency = firstTokenLatency; self.tokensPerSecond = tokensPerSecond; self.providerId = providerId
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) { self.id = id; self.name = name; self.arguments = arguments }
}

/// A local image handed to a vision-capable provider. Always a file on this device; never uploaded by the runtime.
public struct ModelImage: Codable, Sendable, Equatable {
    public var attachmentId: UUID
    public var filePath: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public init(attachmentId: UUID, filePath: String, pixelWidth: Int, pixelHeight: Int) {
        self.attachmentId = attachmentId; self.filePath = filePath; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

public struct ModelMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallId: String?
    public var images: [ModelImage]
    /// Privacy class of a tool result (nil = conversation text). Personal results are withheld from cloud models
    /// unless the person allowed it.
    public var dataClass: DataClass?
    public var reasoningContent: String?
    public init(role: Role, text: String, toolCalls: [ToolCall] = [], toolCallId: String? = nil, images: [ModelImage] = [], dataClass: DataClass? = nil, reasoningContent: String? = nil) {
        self.role = role; self.text = text; self.toolCalls = toolCalls; self.toolCallId = toolCallId; self.images = images; self.dataClass = dataClass; self.reasoningContent = reasoningContent
    }
    enum CodingKeys: String, CodingKey { case role, text, toolCalls, toolCallId, images, dataClass, reasoningContent }
    /// Tolerates snapshots written before `images` existed (schema migration without a version bump).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role); text = try c.decode(String.self, forKey: .text)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        images = try c.decodeIfPresent([ModelImage].self, forKey: .images) ?? []
        dataClass = try c.decodeIfPresent(DataClass.self, forKey: .dataClass)
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
    }
}
