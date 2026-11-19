import Foundation
import Observation
import AgentRuntime
import AssistantCore
import RemoteAgent

/// The one place where what really happens (agent run events, the voice session, microphone and playback measurements, a task on the
/// person's Mac) becomes `CompanionCue`s for the character. All rules live in `CompanionReducer` (AgentRuntime, unit-tested); this
/// class only feeds it in arrival order, publishes what it returns and runs the one timer it needs (an outcome settles to idle).
///
/// Read `cue` (observable snapshot, updated at most ~30×/s while levels move) or `stream()` (ordered, bounded, starts with the current cue).
/// Everything is transient: nothing is persisted and no history is kept.
@MainActor @Observable
final class CompanionSignalHub {
    static let shared = CompanionSignalHub()

    /// The latest snapshot. `sequence` only grows; a consumer ignores anything older than what it has applied.
    private(set) var cue = CompanionCue()

    @ObservationIgnored private var reducer: CompanionReducer
    @ObservationIgnored private let translator = CompanionVoiceTranslator()
    @ObservationIgnored private var continuations: [UUID: AsyncStream<CompanionCue>.Continuation] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCause: CompanionCause?
    /// Tool name → operation category, kept current by `AgentPlatform` when it builds the tool registry.
    @ObservationIgnored let operations: CompanionOperationTable

    init() {
        let table = CompanionOperationTable()
        var config = CompanionReducer.Config()
        config.operation = { table.lookup($0) }
        operations = table
        reducer = CompanionReducer(config: config)
    }

    // MARK: Output

    /// Ordered cues, bounded (a slow reader loses the oldest). The first element is the current cue.
    func stream() -> AsyncStream<CompanionCue> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CompanionCue>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        continuation.yield(cue)
        return stream
    }

    // MARK: Input

    func send(_ input: CompanionInput, at now: Date = .now) {
        for produced in reducer.apply(input, at: now) { publish(produced) }
    }

    /// An event of a run on this device (local or cloud model). `turn` is the user turn it answers, when known.
    func agentEvent(_ event: AgentEvent, turn: UUID?, origin: CompanionOrigin) {
        send(.agent(event, turn: turn, origin: origin))
    }

    /// Inputs produced by a `RemoteCompanionBridge` for a task on the person's Mac.
    func remote(_ inputs: [CompanionInput]) { for input in inputs { send(input) } }

    func note(_ note: CompanionNote) {
        switch note {
        case .session(let old, let new, let conversation, let spoken):
            let cause = pendingCause
            if old.generation != new.generation { pendingCause = nil }
            for signal in translator.session(oldPhase: old.phase.rawValue, oldTurn: old.generation, newPhase: new.phase.rawValue,
                                             newTurn: new.generation, conversation: conversation, spoken: spoken, cause: cause) {
                send(.voice(signal))
            }
        case .mic(.preparing): send(.voice(.micPreparing))
        case .mic(.live): send(.voice(.micLive))
        case .mic(.off): send(.voice(.micOff))
        case .micLevel(let level): send(.voice(.micLevel(level)))
        case .micVoice(let active): send(.voice(.micVoice(active)))
        case .speechLevel(let level): send(.voice(.speechLevel(level)))
        case .speechPreparing(let turn): send(.voice(.speechPreparing(turn: turn)))
        case .speechChunk(let turn, let start): send(.voice(.speechChunkStarted(turn: turn, sourceStart: start)))
        case .speechStopped(let turn, let cause): send(.voice(.speechStopped(turn: turn, cause: CompanionCause(rawValue: cause) ?? .superseded)))
        case .endCause(let cause): pendingCause = CompanionCause(rawValue: cause)
        case .focus(let conversation): send(.voice(.focus(conversation: conversation)))
        }
    }

    // MARK: Publishing

    private func publish(_ produced: CompanionCue) {
        cue = produced
        for (_, continuation) in continuations { continuation.yield(produced) }
        switch produced.event {
        case .completed, .failed, .cancelled, .interrupted: scheduleSettle(afterSequence: produced.sequence)
        default: break
        }
    }

    /// An outcome stays visible for a moment, then the character is idle. The sequence guards against a timer of an older outcome.
    private func scheduleSettle(afterSequence sequence: Int) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.send(.settle(afterSequence: sequence))
        }
    }
}

/// Tool name → operation category from the tools' declared capability (a fixed table, never from text). Read from the reducer on any
/// thread, so it is lock-protected.
final class CompanionOperationTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: CompanionOperation] = [:]

    func update(_ registry: ToolRegistry) {
        var next: [String: CompanionOperation] = [:]
        for name in registry.names {
            if let spec = registry.tool(named: name)?.spec { next[name] = CompanionOperation.of(spec.capability, hasSideEffect: spec.hasSideEffect) }
        }
        lock.withLock { table = next }
    }

    func lookup(_ name: String) -> CompanionOperation? { lock.withLock { table[name] } }
}

extension CompanionOrigin {
    /// Where a run executes, from the provider that serves it.
    init(provider kind: ProviderKind) { self = kind == .cloudGateway ? .cloudAgent : .localAgent }
}

/// One Mac task's feed into the hub: its event log and the transport's reconnecting/connected, through `RemoteCompanionBridge`
/// (replays by sequence are dropped there). Create one per watched task; `conversationId` is what `CompanionVoiceSignal.focus` takes
/// while the task is on screen.
@MainActor final class RemoteCompanionFeed {
    private var bridge: RemoteCompanionBridge
    init(taskId: String) { bridge = RemoteCompanionBridge(taskId: taskId) }
    var conversationId: UUID { bridge.conversationId }
    func event(_ event: RemoteEvent) { CompanionSignalHub.shared.remote(bridge.inputs(for: event)) }
    func connection(_ status: RemoteConnectionStatus) { CompanionSignalHub.shared.remote(bridge.connection(status)) }
}
