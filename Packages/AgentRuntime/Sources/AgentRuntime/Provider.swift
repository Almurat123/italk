import Foundation

/// One contract for Apple Foundation Models, downloaded local models and the paid iTalk cloud gateway.
public enum ProviderKind: String, Codable, Sendable { case appleFoundation, localDownloaded, cloudGateway }

public enum ToolCallingLevel: String, Codable, Sendable, Comparable {
    case none, constrained, native
    private var rank: Int { switch self { case .none: 0; case .constrained: 1; case .native: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// How much the runtime lets a model plan on its own. Set from measured results, not parameter count.
public enum AutonomyLevel: Int, Codable, Sendable, Comparable {
    /// Conversation only. Deterministic routes may still call read-only tools; the model proposes nothing.
    case chatOnly = 0
    /// Model may propose read-only tool calls; every state change needs user approval.
    case restrictedTools = 1
    /// Multi-step planning with approval-gated side effects.
    case fullAgent = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How a model reaches the right skill. `native`: it sees the whole catalog and calls `load_skill` itself (strong models).
/// `guided`: the runtime first asks the model one short question — "which skills does this request need?" — and hands the
/// answer's tools to the real step. The choice is still the model's (no keyword routing); it only removes a two-level
/// protocol that small models fail at. Chosen from measured tool-use results, never from parameter count.
public enum SkillSelectionMode: String, Codable, Sendable { case native, guided }

public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public var skillSelection: SkillSelectionMode = .native
    /// The window this device allocates and budgets against (tested; memory-safe). Not what the model advertises.
    public var contextWindow: Int
    /// What the model supports on paper (nil = unknown). Reported next to `contextWindow`, never used as a budget.
    public var advertisedWindow: Int? = nil
    public var streaming: Bool
    public var toolCalling: ToolCallingLevel
    public var structuredOutput: Bool
    public var maxAutonomy: AutonomyLevel
    /// True when inference works with the radio off.
    public var worksOffline: Bool
    /// True when prompt content leaves the device. Drives consent gating.
    public var sendsContentOffDevice: Bool
    /// Estimated resident memory once loaded (0 for cloud).
    public var estimatedResidentBytes: Int64
    /// Accepts images in `ModelMessage.images`. Set only after real inference on the target device class works.
    public var visionInput: Bool
    public init(contextWindow: Int, streaming: Bool = true, toolCalling: ToolCallingLevel, structuredOutput: Bool, maxAutonomy: AutonomyLevel, worksOffline: Bool, sendsContentOffDevice: Bool, estimatedResidentBytes: Int64 = 0, visionInput: Bool = false, skillSelection: SkillSelectionMode = .native) {
        self.visionInput = visionInput; self.skillSelection = skillSelection
        self.contextWindow = contextWindow; self.streaming = streaming; self.toolCalling = toolCalling
        self.structuredOutput = structuredOutput; self.maxAutonomy = maxAutonomy; self.worksOffline = worksOffline
        self.sendsContentOffDevice = sendsContentOffDevice; self.estimatedResidentBytes = estimatedResidentBytes
    }
}

public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var displayName: String
    public var capabilities: ProviderCapabilities
    public init(id: String, kind: ProviderKind, displayName: String, capabilities: ProviderCapabilities) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.capabilities = capabilities
    }
}

public struct GenerationRequest: Sendable {
    public var requestId: String
    public var messages: [ModelMessage]
    public var tools: [ToolSpec]
    /// JSON-schema-like constraint for structured output; providers without support must throw `.unsupported`.
    public var responseSchema: JSONValue?
    public var maxTokens: Int
    public var temperature: Double
    /// Ask the model to reason before answering (local: thinking mode; cloud: reasoning summaries if the service offers them).
    /// Providers that cannot reason ignore it and emit no reasoning — nothing is ever invented.
    public var reasoning: Bool
    public init(requestId: String = UUID().uuidString, messages: [ModelMessage], tools: [ToolSpec] = [], responseSchema: JSONValue? = nil, maxTokens: Int = 512, temperature: Double = 0.6, reasoning: Bool = false) {
        self.requestId = requestId; self.messages = messages; self.tools = tools
        self.responseSchema = responseSchema; self.maxTokens = maxTokens; self.temperature = temperature; self.reasoning = reasoning
    }
}

public enum GenerationEvent: Sendable, Equatable {
    /// Display- and speech-safe text. Tool-call markup is never delivered here.
    case textDelta(String)
    /// The model's own reasoning, exactly as it produced it. Never shown as the answer, never spoken, never fed back as context.
    case reasoningDelta(String)
    /// A complete, parsed proposal. Partial calls are never emitted; the runtime still validates it.
    case toolCall(ToolCall)
    case usage(Usage)
    case completed(FinishReason)
}

public enum FinishReason: String, Codable, Sendable { case stop, length, toolCalls }

public enum ProviderError: Error, Sendable, Equatable {
    case notPrepared
    case unsupported(String)
    case insufficientResources(String)
    case network
    case cancelled
    case incompleteStream
    case failed(String)
}

public enum PreparationState: Sendable, Equatable {
    case idle
    case checkingResources
    case loading(fraction: Double?)
    case ready
    case failed(String)
    case unloaded
}

public protocol ModelProvider: Sendable {
    var descriptor: ModelDescriptor { get }
    /// Loads weights / validates credentials. Reports progress so the UI never looks frozen.
    func prepare(progress: @Sendable (PreparationState) -> Void) async throws
    /// Cancelling the consuming task, or terminating the stream, must stop generation promptly.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    /// Releases weights and KV cache. Safe to call repeatedly.
    func unload() async
    /// The exact number of prompt tokens `request` occupies for this model (its own tokenizer and chat template, tool schemas included), or nil when the
    /// provider cannot count. Must not generate. The runner trusts this over any estimate.
    func promptTokenCount(_ request: GenerationRequest) async -> Int?
}

public extension ModelProvider {
    func promptTokenCount(_ request: GenerationRequest) async -> Int? { nil }
}

// MARK: - Routing: local first, cloud only by explicit user choice

public struct ModelPolicy: Codable, Sendable, Equatable {
    public var preferredLocalId: String?
    /// User switched on iTalk cloud models.
    public var cloudEnabled: Bool
    /// User has read and accepted the cloud-processing disclosure.
    public var cloudConsentGranted: Bool
    /// Server-verified entitlement; never a local flag alone.
    public var cloudEntitled: Bool
    public var cloudHealthConsent: Bool
    public init(preferredLocalId: String? = nil, cloudEnabled: Bool = false, cloudConsentGranted: Bool = false, cloudEntitled: Bool = false, cloudHealthConsent: Bool = false) {
        self.preferredLocalId = preferredLocalId; self.cloudEnabled = cloudEnabled; self.cloudConsentGranted = cloudConsentGranted
        self.cloudEntitled = cloudEntitled; self.cloudHealthConsent = cloudHealthConsent
    }
}

public enum RoutingDecision: Sendable, Equatable {
    case use(ModelDescriptor)
    /// Nothing is sent anywhere. The UI must ask the person.
    case needsUserChoice(RoutingBlock)
}

public enum RoutingBlock: String, Codable, Sendable {
    case noLocalModelInstalled, cloudNeedsConsent, cloudNeedsSubscription, cloudHealthNeedsConsent, localUnavailableOfferCloud
}

public struct RoutingContext: Sendable {
    public var involvesHealthData: Bool
    public var userRequestedCloud: Bool
    public var localUsable: Bool
    public init(involvesHealthData: Bool = false, userRequestedCloud: Bool = false, localUsable: Bool = true) {
        self.involvesHealthData = involvesHealthData; self.userRequestedCloud = userRequestedCloud; self.localUsable = localUsable
    }
}

public struct ModelRouter: Sendable {
    public var installed: [ModelDescriptor]
    public var cloud: ModelDescriptor?
    public init(installed: [ModelDescriptor], cloud: ModelDescriptor?) { self.installed = installed; self.cloud = cloud }

    /// Free users never fall into billable cloud inference. An expired subscription falls back to local, with all local history intact.
    public func route(policy: ModelPolicy, context: RoutingContext) -> RoutingDecision {
        let local = installed.first { $0.id == policy.preferredLocalId } ?? installed.first { $0.kind == .appleFoundation } ?? installed.first
        let wantsCloud = context.userRequestedCloud || (policy.cloudEnabled && !context.localUsable)
        if wantsCloud, let cloud {
            if !policy.cloudEnabled || !policy.cloudConsentGranted { return .needsUserChoice(.cloudNeedsConsent) }
            if !policy.cloudEntitled { return .needsUserChoice(.cloudNeedsSubscription) }
            if context.involvesHealthData && !policy.cloudHealthConsent { return .needsUserChoice(.cloudHealthNeedsConsent) }
            return .use(cloud)
        }
        if let local, context.localUsable { return .use(local) }
        if cloud != nil { return .needsUserChoice(.localUnavailableOfferCloud) }
        return .needsUserChoice(.noLocalModelInstalled)
    }
}
