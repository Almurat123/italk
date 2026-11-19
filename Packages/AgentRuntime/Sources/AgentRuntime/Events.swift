import Foundation

public enum Visibility: String, Codable, Sendable {
    /// Safe progress text for UI and operational logs.
    case activity
    /// The person's own content (conversation text, tool output). UI only; stripped from logs and exports.
    case content
    /// Developer diagnostics. Never shown in consumer UI.
    case diagnostic
}

public enum AgentEventType: String, Codable, Sendable {
    case runCreated = "run.created", runStarted = "run.started", runResumed = "run.resumed", runSuspended = "run.suspended"
    case runCompleted = "run.completed", runFailed = "run.failed", runCancelled = "run.cancelled", runState = "run.state"
    case modelStarted = "model.request.started", modelDelta = "model.output.delta", modelCompleted = "model.request.completed"
    case reasoningDelta = "model.reasoning.delta"
    case skillDiscovered = "skill.discovered", skillLoaded = "skill.loaded"
    case toolProposed = "tool.proposed", toolValidated = "tool.arguments.validated", toolStarted = "tool.started"
    case toolProgress = "tool.progress", toolCompleted = "tool.completed", toolFailed = "tool.failed"
    case approvalRequested = "approval.requested", approvalResolved = "approval.resolved"
    case uiCreated = "ui.component.created", uiUpdated = "ui.component.updated", uiCompleted = "ui.component.completed", uiRemoved = "ui.component.removed"
    case speechStarted = "speech.started", speechInterrupted = "speech.interrupted", speechCompleted = "speech.completed"
    case usageUpdated = "usage.updated"
    /// Transient (never stored): where a segment of the answer starts and the tone the model declared for it. See `ToneProtocol`.
    case companionSegment = "companion.segment"
}

public enum EventPayload: Codable, Sendable, Equatable {
    case state(from: RunState, to: RunState, reason: String?)
    case message(String)
    case textDelta(String)
    case modelRequest(providerId: String, step: Int)
    case modelFinished(providerId: String, finish: FinishReason)
    case skill(id: String, method: String)
    case toolCall(callId: String, name: String)
    case toolSummary(callId: String, name: String, summary: String)
    case toolError(callId: String, name: String, code: String)
    case approval(approvalId: String, summary: String, approved: Bool?)
    case component(UIComponent)
    case componentRef(id: String)
    case usage(Usage)
    case activity(ToolActivity)
    case segment(ToneSegment)
    case redacted
}

/// Versioned envelope shared by local and cloud execution.
public struct AgentEvent: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1
    public var schemaVersion: Int = AgentEvent.schemaVersion
    public var eventId: UUID
    public var runId: UUID
    public var conversationId: UUID
    public var stepId: String
    public var parentId: UUID?
    public var sequence: Int
    public var timestamp: Date
    public var type: AgentEventType
    public var visibility: Visibility
    public var payload: EventPayload
    public var id: UUID { eventId }

    /// Public so adapters outside this package (the Mac task bridge) can express their own events in the same envelope.
    public init(eventId: UUID = UUID(), runId: UUID, conversationId: UUID, stepId: String, parentId: UUID? = nil, sequence: Int,
                timestamp: Date = .now, type: AgentEventType, visibility: Visibility, payload: EventPayload) {
        self.eventId = eventId; self.runId = runId; self.conversationId = conversationId; self.stepId = stepId; self.parentId = parentId
        self.sequence = sequence; self.timestamp = timestamp; self.type = type; self.visibility = visibility; self.payload = payload
    }

    /// Same event with content removed; safe for logs, support bundles and exports.
    public func redacted() -> AgentEvent {
        guard visibility != .activity else { return self }
        var copy = self; copy.payload = .redacted; return copy
    }
}

public actor AgentEventBus {
    private let store: any RunStore
    private var sequences: [UUID: Int] = [:]
    private var seen: [UUID: Set<UUID>] = [:]
    private var subscribers: [UUID: (runId: UUID?, continuation: AsyncStream<AgentEvent>.Continuation)] = [:]
    private var hooks: [@Sendable (AgentEvent) -> Void] = []
    public init(store: any RunStore) { self.store = store }

    public func eventCount(_ runId: UUID) async -> Int { await store.lastSequence(runId: runId) }

    /// Lifecycle hook. Called after the event is durable.
    public func addHook(_ hook: @escaping @Sendable (AgentEvent) -> Void) { hooks.append(hook) }

    /// Bounded: a slow consumer loses the oldest events, never blocks the runner. It can replay from the store.
    public func subscribe(runId: UUID? = nil, buffer: Int = 256) -> AsyncStream<AgentEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(buffer))
        subscribers[id] = (runId, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }
    private func drop(_ id: UUID) { subscribers[id] = nil }

    /// `persist: false` delivers the event to live subscribers only (in order, with its sequence number) and never stores it or runs
    /// the durability hooks. Used for transient companion metadata, which must not become a permanent record.
    @discardableResult
    public func publish(runId: UUID, conversationId: UUID, stepId: String, parentId: UUID? = nil, type: AgentEventType, visibility: Visibility, payload: EventPayload, at date: Date = .now, persist: Bool = true) async -> AgentEvent {
        if sequences[runId] == nil { sequences[runId] = await store.lastSequence(runId: runId) }
        sequences[runId]! += 1
        let event = AgentEvent(eventId: UUID(), runId: runId, conversationId: conversationId, stepId: stepId, parentId: parentId,
                               sequence: sequences[runId]!, timestamp: date, type: type, visibility: visibility, payload: payload)
        seen[runId, default: []].insert(event.eventId)
        if persist { await store.append(event) }
        for (_, s) in subscribers where s.runId == nil || s.runId == runId { s.continuation.yield(event) }
        if persist { for h in hooks { h(event) } }
        return event
    }

    /// Accepts an event produced elsewhere (other device, replay). Rejects duplicates and stale sequence numbers.
    public func ingest(_ event: AgentEvent) async -> Bool {
        guard event.schemaVersion == AgentEvent.schemaVersion else { return false }
        if sequences[event.runId] == nil { sequences[event.runId] = await store.lastSequence(runId: event.runId) }
        guard !(seen[event.runId]?.contains(event.eventId) ?? false), event.sequence > sequences[event.runId]! else { return false }
        sequences[event.runId] = event.sequence
        seen[event.runId, default: []].insert(event.eventId)
        await store.append(event)
        for (_, s) in subscribers where s.runId == nil || s.runId == event.runId { s.continuation.yield(event) }
        return true
    }
}
