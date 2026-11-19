import Foundation

// MARK: - Companion reducer
//
// Folds the facts the app already has (agent run events, the voice session's phases, microphone and playback signals) into one
// ordered stream of `CompanionCue` snapshots. It owns no timers, makes no model request and invents no state: every field of a cue
// is a function of the inputs it has seen. The existing state machines (`RunState`, `VoiceSession`) stay the source of truth.

/// Mirror of `VoicePhase` (AssistantCore), so this package needs no dependency on it. Raw values are identical.
public enum CompanionVoicePhase: String, Codable, Sendable {
    case idle, preparing, listening, finalizing, thinking, synthesizing, confirming, speaking, interrupted, failed
}

public enum CompanionVoiceSignal: Sendable, Equatable {
    /// The turn (voice session generation) moved to `phase`. `.idle` of the current turn is its normal ending.
    case phase(CompanionVoicePhase, turn: UUID, conversation: UUID?, spoken: Bool)
    /// The turn ended without a normal ending: stopped, interrupted, superseded or failed.
    case turnEnded(turn: UUID, cause: CompanionCause)
    case micPreparing, micLive, micOff
    /// One microphone buffer's normalized level (0…1). Evidence that audio flows.
    case micLevel(Double)
    /// Debounced voice activity of the person.
    case micVoice(Bool)
    case speechPreparing(turn: UUID)
    /// Level of what is being played (0…1).
    case speechLevel(Double)
    /// The chunk starting at `sourceStart` (characters of the plain answer text) began playing.
    case speechChunkStarted(turn: UUID, sourceStart: Int)
    case speechStopped(turn: UUID, cause: CompanionCause)
    /// The conversation on screen. Runs of other conversations never move the character.
    case focus(conversation: UUID?)
}

public enum CompanionInput: Sendable {
    case agent(AgentEvent, turn: UUID? = nil, origin: CompanionOrigin = .localAgent, taskId: String? = nil)
    case voice(CompanionVoiceSignal)
    /// A producer that really knows a fraction of the work done (none does today).
    case progress(runId: UUID, fraction: Double)
    /// Moves a finished turn's outcome to idle. `afterSequence` is the sequence of the outcome cue; stale timers do nothing.
    case settle(afterSequence: Int)
    case reset
}

public struct CompanionReducer: Sendable {
    public struct Config: Sendable {
        /// Level cues are rate-limited to this interval…
        public var levelInterval: TimeInterval = 1.0 / 30.0
        /// …and need to move at least this much.
        public var levelStep = 0.02
        public var maxTrackedRuns = 48
        /// Operation category of a tool by name (a fixed table over its declared capability). nil → `.other`.
        public var operation: @Sendable (String) -> CompanionOperation? = { _ in nil }
        public init() {}
    }

    /// Guard events the runner emits as `tool.failed`; they are not tool failures.
    static let guardNames: Set<String> = ["fabricated_claim", "skipped_tool", "unsupported_figures"]

    public let config: Config
    /// The latest snapshot.
    public private(set) var cue: CompanionCue

    // MARK: State

    private struct SegmentRecord { var index: Int; var plainStart: Int; var intent: CompanionIntent; var intensity: Double? }

    private struct Track {
        var conversationId: UUID
        var origin: CompanionOrigin
        var lastSequence = 0
        var state: RunState = .created
        var terminal: RunState?
        var failure: String?
        var providerId: String?
        var openTools: [(callId: String, operation: CompanionOperation)] = []
        var closedTools: Set<String> = []
        var pendingApprovals: Set<String> = []
        var succeeded = 0, failed = 0, declined = 0
        var stepText = ""
        var answering = false
        var segments: [SegmentRecord] = []
        var connectivity: CompanionConnectivity = .live
        var progress: Double?
        init(conversationId: UUID, origin: CompanionOrigin) { self.conversationId = conversationId; self.origin = origin }
    }

    private struct Turn {
        var id: UUID
        var conversationId: UUID?
        var spoken: Bool
        var hasVoiceLayer: Bool
        var voice: CompanionVoicePhase
        var runId: UUID?
        var origin: CompanionOrigin
        var taskId: String?
        var voiceIdle = false
        /// Plain-text offset of the chunk being played (the speech clock of a spoken turn).
        var chunkStart: Int?
        var outcome: CompanionPhase?
        var outcomeSequence = 0
    }

    private var sequence = 0
    private var turn: Turn?
    private var runs: [UUID: Track] = [:]
    private var runOrder: [UUID] = []
    private var endedRuns: [UUID] = []
    private var endedTurns: [UUID] = []
    private var focus: UUID?
    private var mic = CompanionAudio.off
    /// The microphone level last published. nil until a level was measured in the current listening stretch (before that it is
    /// "no signal", not silence). Only moves when a level cue is emitted, so a cue never carries an un-throttled value.
    private var micShown: Double?
    private var userSpeaking = false
    private var speech = CompanionAudio.off
    private var speechTurn: UUID?
    private var lastMicEmit = Date.distantPast, lastMicLevel = -1.0
    private var lastSpeechEmit = Date.distantPast, lastSpeechLevel = -1.0
    private var emitted: [CompanionCue] = []

    public init(config: Config = Config(), now: Date = .now) {
        self.config = config
        self.cue = CompanionCue(sequence: 0, timestamp: now)
    }

    // MARK: Entry point

    /// Applies one input and returns the cues it produced, in order (usually zero or one).
    @discardableResult
    public mutating func apply(_ input: CompanionInput, at now: Date = .now) -> [CompanionCue] {
        emitted = []
        switch input {
        case .agent(let event, let turnId, let origin, let taskId): agent(event, turnId: turnId, origin: origin, taskId: taskId, now: now)
        case .voice(let signal): voice(signal, now: now)
        case .progress(let runId, let fraction):
            if runs[runId] != nil, !endedRuns.contains(runId) { runs[runId]?.progress = CompanionLevel.clamped(fraction) }
        case .settle(let n):
            if let t = turn, t.outcome != nil, t.outcomeSequence == n { turn = nil; speech = .off; speechTurn = nil; userSpeaking = false }
        case .reset:
            turn = nil; runs = [:]; runOrder = []; endedRuns = []; endedTurns = []; mic = .off; micShown = nil
            userSpeaking = false
            speech = .off; speechTurn = nil; lastMicLevel = -1; lastSpeechLevel = -1
        }
        commit(.snapshot, nil, now)
        return emitted
    }

    // MARK: Agent events

    private enum Effect { case event(CompanionEventKind, String?), none }
    private enum ToolOutcome { case succeeded, failed, declined, quiet }

    private mutating func agent(_ e: AgentEvent, turnId: UUID?, origin: CompanionOrigin, taskId: String?, now: Date) {
        if endedRuns.contains(e.runId) { return }
        if let turnId, endedTurns.contains(turnId) { return }
        var track = runs[e.runId] ?? Track(conversationId: e.conversationId, origin: origin)
        let known = runs[e.runId] != nil
        // Replays after a reconnect (and anything already seen) never act twice.
        if known, e.sequence <= track.lastSequence { return }
        track.lastSequence = max(track.lastSequence, e.sequence)
        track.origin = origin
        let effect = fold(e, into: &track)
        runs[e.runId] = track
        if !known { runOrder.append(e.runId); trimRuns() }

        // Which turn does this run belong to?
        var belongs = false
        if var t = turn, t.outcome == nil || t.runId == e.runId {
            if t.runId == e.runId || (turnId != nil && t.id == turnId) {
                belongs = true
            } else if turnId == nil, t.runId == nil, t.hasVoiceLayer, t.conversationId == e.conversationId, Self.startsTurn(e) {
                belongs = true
            }
            if belongs { t.runId = e.runId; t.origin = origin; if let taskId { t.taskId = taskId }; turn = t }
        }
        if !belongs, track.terminal == nil, Self.startsTurn(e), focus == nil || focus == e.conversationId, turn?.outcome != nil || turn == nil {
            let id = turnId ?? e.runId
            if !endedTurns.contains(id) {
                speech = .off; speechTurn = nil; userSpeaking = false
                turn = Turn(id: id, conversationId: e.conversationId, spoken: false, hasVoiceLayer: false, voice: .thinking, runId: e.runId,
                            origin: origin, taskId: taskId)
                belongs = true
                commit(.turnStarted, nil, now)
            }
        }
        guard belongs else { return }
        if case .event(let kind, let detail) = effect { commit(kind, detail, now) }
        if track.terminal != nil { evaluateOutcome(now: now) }
    }

    /// Per-run state transition. Returns the discrete event to publish, if any.
    private func fold(_ e: AgentEvent, into t: inout Track) -> Effect {
        switch e.type {
        case .runState:
            guard case .state(_, let to, let reason) = e.payload else { return .none }
            t.state = to
            switch to {
            case .awaitingNetwork:
                guard t.connectivity != .reconnecting else { return .none }
                t.connectivity = .reconnecting
                return .event(.reconnecting, reason)
            case .suspended, .awaitingForeground:
                t.connectivity = .paused
            case .completed, .failed, .cancelled, .expired:
                t.terminal = to
                if to == .failed, let reason { t.failure = reason }
            case .created, .queued, .planning, .running, .awaitingTool, .awaitingApproval, .resuming:
                if t.connectivity != .live { t.connectivity = .live; return .event(.resumed, nil) }
            }
        case .runCompleted: t.terminal = t.terminal ?? .completed
        case .runFailed:
            t.terminal = t.terminal ?? .failed
            if case .message(let code) = e.payload { t.failure = code }
        case .runCancelled: t.terminal = t.terminal ?? .cancelled
        case .runResumed:
            if t.connectivity != .live { t.connectivity = .live; return .event(.resumed, nil) }
        case .modelStarted:
            guard case .modelRequest(let provider, _) = e.payload else { return .none }
            t.stepText = ""; t.segments = []; t.answering = false
            let switched = t.providerId != nil && t.providerId != provider
            t.providerId = provider
            if switched { return .event(.modelSwitched, provider) }
        case .modelDelta:
            if case .textDelta(let d) = e.payload { t.stepText += d; if !d.isEmpty { t.answering = true } }
        case .modelCompleted: t.answering = false; t.stepText = ""        // only needed while later segments of this step can still arrive
        case .companionSegment:
            guard case .segment(let s) = e.payload else { return .none }
            t.segments.append(SegmentRecord(index: s.index, plainStart: TextSanitizer.plain(t.stepText).count,
                                            intent: CompanionIntent(rawValue: s.label) ?? .neutral,
                                            intensity: s.intensity.map(CompanionLevel.clamped)))
        case .toolStarted:
            guard case .toolCall(let id, let name) = e.payload else { return .none }
            let op = config.operation(name) ?? .other
            if Self.open(&t, id, op) { return .event(.toolStarted, op.rawValue) }
        case .toolProgress:
            guard case .activity(let a) = e.payload else { return .none }
            return fold(a, into: &t)
        case .toolCompleted:
            if case .toolSummary(let id, _, _) = e.payload, Self.finish(&t, id, .succeeded) { return .event(.toolSucceeded, nil) }
        case .toolFailed:
            guard case .toolError(let id, let name, let code) = e.payload, !Self.guardNames.contains(name) else { return .none }
            let outcome: ToolOutcome
            switch code {
            case "user_declined": outcome = .declined
            case "retryable", "failed": outcome = .failed
            case _ where code.hasPrefix("permission_"): outcome = .failed
            default: outcome = .quiet          // the model's malformed or repeated call, a policy denial: it is retried or explained, not an execution failure
            }
            t.pendingApprovals.remove(id)
            if Self.finish(&t, id, outcome) { return outcome == .failed ? .event(.toolFailed, code) : .none }
        case .approvalRequested:
            t.pendingApprovals.insert(e.stepId)
            return .event(.approvalRequested, nil)
        case .approvalResolved:
            guard case .approval(_, _, let approved) = e.payload else { return .none }
            t.pendingApprovals.remove(e.stepId)
            return .event(.approvalResolved, approved == true ? "approved" : "declined")
        case .runCreated, .runStarted, .runSuspended, .reasoningDelta, .skillDiscovered, .skillLoaded, .toolProposed, .toolValidated,
             .uiCreated, .uiUpdated, .uiCompleted, .uiRemoved, .speechStarted, .speechInterrupted, .speechCompleted, .usageUpdated:
            break
        }
        return .none
    }

    private func fold(_ a: ToolActivity, into t: inout Track) -> Effect {
        switch a.kind {
        case .skill: return .none            // loading a skill is not tool work
        case .approval:
            switch a.state {
            case .awaitingApproval: t.pendingApprovals.insert(a.callId)
            case .running: t.pendingApprovals.remove(a.callId)       // approved: the tool starts next
            case .declined:
                t.pendingApprovals.remove(a.callId)
                _ = Self.finish(&t, a.callId, .declined)
            default: break
            }
        case .tool, .web:
            switch a.state {
            case .running:
                let op = a.operation ?? config.operation(a.name) ?? (a.kind == .web ? .lookup : .other)
                if Self.open(&t, a.callId, op) { return .event(.toolStarted, op.rawValue) }
                // Opened earlier by the bare `tool.started` event: the activity knows the category better.
                if let known = a.operation, let i = t.openTools.firstIndex(where: { $0.callId == a.callId }) { t.openTools[i].operation = known }
            case .succeeded: if Self.finish(&t, a.callId, .succeeded) { return .event(.toolSucceeded, nil) }
            case .failed, .needsPermission: if Self.finish(&t, a.callId, .failed) { return .event(.toolFailed, a.state.rawValue) }
            case .declined: _ = Self.finish(&t, a.callId, .declined)
            case .cancelled: _ = Self.finish(&t, a.callId, .quiet)
            case .awaitingApproval: t.pendingApprovals.insert(a.callId)
            }
        }
        return .none
    }

    private static func open(_ t: inout Track, _ id: String, _ op: CompanionOperation) -> Bool {
        guard !t.closedTools.contains(id), !t.openTools.contains(where: { $0.callId == id }) else { return false }
        t.openTools.append((id, op))
        return true
    }

    /// Closes a call once. Returns false when it was already closed (the runner reports most outcomes twice).
    private static func finish(_ t: inout Track, _ id: String, _ outcome: ToolOutcome) -> Bool {
        t.openTools.removeAll { $0.callId == id }
        guard !t.closedTools.contains(id) else { return false }
        t.closedTools.insert(id)
        switch outcome {
        case .succeeded: t.succeeded += 1
        case .failed: t.failed += 1
        case .declined: t.declined += 1
        case .quiet: break
        }
        return true
    }

    /// Events that may start a turn of their own (a late text delta or terminal event never does).
    private static func startsTurn(_ e: AgentEvent) -> Bool {
        switch e.type {
        case .runCreated, .runStarted, .runResumed, .modelStarted, .toolStarted, .approvalRequested: return true
        case .runState:
            if case .state(_, let to, _) = e.payload { return !to.isTerminal }
            return false
        default: return false
        }
    }

    private mutating func trimRuns() {
        while runOrder.count > config.maxTrackedRuns, let oldest = runOrder.first {
            if oldest == turn?.runId { break }
            runOrder.removeFirst(); runs[oldest] = nil
        }
    }

    // MARK: Voice signals

    private mutating func voice(_ s: CompanionVoiceSignal, now: Date) {
        switch s {
        case .phase(let p, let id, let conversation, let spoken):
            if endedTurns.contains(id) { return }
            if p == .idle {
                // The normal ending of the current turn; an idle that belongs to no turn of ours is ignored.
                guard var t = turn, t.id == id, t.outcome == nil else { return }
                t.hasVoiceLayer = true; t.voiceIdle = true; t.voice = .idle
                turn = t
                micShown = nil; lastMicLevel = -1
                endSpeech(for: id, cause: nil, now: now)
                evaluateOutcome(now: now)
                return
            }
            if p != .listening { micShown = nil; lastMicLevel = -1 }       // the next listening stretch starts from "nothing measured"
            var started = false
            if turn?.id != id || turn?.outcome != nil {
                speech = .off; speechTurn = nil; userSpeaking = false
                turn = Turn(id: id, conversationId: conversation, spoken: spoken, hasVoiceLayer: true, voice: p, runId: nil, origin: .voice)
                started = true
            }
            turn?.voice = p; turn?.spoken = spoken; turn?.hasVoiceLayer = true
            if let conversation { turn?.conversationId = conversation }
            switch p {
            case .synthesizing:
                if speechTurn != id || speech.availability == .off { speech = CompanionAudio(availability: .preparing); speechTurn = id }
            case .speaking:
                if speech.availability != .live || speechTurn != id {
                    speech = CompanionAudio(availability: .live, level: nil, active: false); speechTurn = id
                    commit(.speechStarted, nil, now)
                }
            case .interrupted: release(.interrupted, "voice_interrupted", now: now); return
            case .failed: release(.failed, "voice_error", now: now); return
            default: endSpeech(for: id, cause: nil, now: now)       // playback ended before the phase moved on
            }
            if started { commit(.turnStarted, nil, now) }
        case .turnEnded(let id, let cause):
            guard let t = turn, t.id == id, t.outcome == nil else { return }
            endSpeech(for: id, cause: cause, now: now)
            switch cause {
            case .userSpeech, .userTap, .systemAudio, .routeChange, .background: release(.interrupted, cause.rawValue, now: now)
            case .userStop, .superseded, .expired: release(.cancelled, cause.rawValue, now: now)
            case .error: release(.failed, cause.rawValue, now: now)
            }
        case .micPreparing:
            mic = CompanionAudio(availability: .preparing); userSpeaking = false; micShown = nil; lastMicLevel = -1
        case .micLive:
            mic.availability = .live
        case .micOff:
            mic = .off; userSpeaking = false; micShown = nil; lastMicLevel = -1
        case .micLevel(let v):
            let level = CompanionLevel.clamped(v)
            mic.availability = .live                                     // audio frames are the evidence
            guard attending else { return }
            if now.timeIntervalSince(lastMicEmit) >= config.levelInterval, abs(level - lastMicLevel) >= config.levelStep {
                lastMicEmit = now; lastMicLevel = level; micShown = level
                commit(.level, nil, now)
            }
        case .micVoice(let active):
            guard mic.availability == .live, active != userSpeaking else { return }
            userSpeaking = active
            if attending { commit(active ? .userSpeechStarted : .userSpeechEnded, nil, now) }
        case .speechPreparing(let id):
            guard let t = turn, t.id == id, t.outcome == nil else { return }
            if speech.availability == .off { speech = CompanionAudio(availability: .preparing); speechTurn = id }
        case .speechLevel(let v):
            guard speech.availability == .live, let t = turn, t.outcome == nil, speechTurn == t.id else { return }
            let level = CompanionLevel.clamped(v)
            if now.timeIntervalSince(lastSpeechEmit) >= config.levelInterval, abs(level - lastSpeechLevel) >= config.levelStep {
                lastSpeechEmit = now; lastSpeechLevel = level
                speech.level = level; speech.active = level >= 0.04
                commit(.level, nil, now)
            }
        case .speechChunkStarted(let id, let start):
            guard let t = turn, t.id == id, t.outcome == nil, speechTurn == id, speech.availability == .live else { return }
            turn?.chunkStart = start
        case .speechStopped(let id, let cause):
            guard let t = turn, t.id == id else { return }
            endSpeech(for: id, cause: cause, now: now)
        case .focus(let conversation):
            focus = conversation
        }
    }

    /// The microphone is open and the assistant is attending to the person.
    private var attending: Bool { mic.availability == .live && turn?.voice == .listening && turn?.outcome == nil }

    /// Speech of `id` ended (normally, or cut off by `cause`): the audio fields go dark at once.
    private mutating func endSpeech(for id: UUID, cause: CompanionCause?, now: Date) {
        guard speechTurn == id, speech.availability != .off else { return }
        let wasLive = speech.availability == .live
        speech = .off; speechTurn = nil; lastSpeechLevel = -1
        turn?.chunkStart = nil
        if wasLive { commit(.speechEnded, cause?.rawValue, now) }
    }

    // MARK: Outcomes

    /// Releases the turn's outcome when the facts allow it. Completion waits for the voice layer of a spoken turn; an agent-side
    /// cancellation is decided by the voice layer (barge-in vs stop), so it only counts for turns without one.
    private mutating func evaluateOutcome(now: Date) {
        guard let t = turn, t.outcome == nil else { return }
        let track = t.runId.flatMap { runs[$0] }
        if let terminal = track?.terminal {
            switch terminal {
            case .failed: release(.failed, track?.failure ?? "run_failed", now: now)
            case .cancelled where !t.hasVoiceLayer: release(.cancelled, CompanionCause.userStop.rawValue, now: now)
            case .expired where !t.hasVoiceLayer: release(.cancelled, CompanionCause.expired.rawValue, now: now)
            case .completed where !t.hasVoiceLayer || t.voiceIdle: release(.completed, nil, now: now)
            default: break
            }
        } else if t.hasVoiceLayer, t.voiceIdle, t.runId == nil {
            release(.completed, nil, now: now)                           // a voice turn that needed no model run
        }
    }

    private mutating func release(_ phase: CompanionPhase, _ detail: String?, now: Date) {
        guard var t = turn, t.outcome == nil else { return }
        t.outcome = phase
        turn = t
        speech = .off; speechTurn = nil; lastSpeechLevel = -1
        endedTurns.append(t.id); if endedTurns.count > 64 { endedTurns.removeFirst() }
        if let r = t.runId { endedRuns.append(r); if endedRuns.count > 64 { endedRuns.removeFirst() } }
        let kind: CompanionEventKind
        switch phase {
        case .completed: kind = .completed
        case .failed: kind = .failed
        case .cancelled: kind = .cancelled
        default: kind = .interrupted
        }
        commit(kind, detail, now)
        turn?.outcomeSequence = cue.sequence
    }

    // MARK: Snapshot

    private mutating func commit(_ kind: CompanionEventKind, _ detail: String?, _ now: Date) {
        var next = snapshot(now: now)
        if kind == .snapshot || kind == .level {
            if next.sameState(as: cue) { return }
            if kind == .level { next.event = .level }
            else if next.phase != cue.phase { next.event = .phaseChanged }
            else if next.segment != cue.segment { next.event = .segmentStarted }
            else { next.event = .snapshot }
        } else {
            next.event = kind; next.detail = detail
        }
        sequence += 1
        next.sequence = sequence
        cue = next
        emitted.append(next)
    }

    private func snapshot(now: Date) -> CompanionCue {
        var c = CompanionCue(timestamp: now)
        var micState = mic
        if micState.availability == .live {
            micState.level = attending ? micShown : nil
            micState.active = attending && userSpeaking
        } else { micState.level = nil; micState.active = false }
        c.mic = micState
        guard let t = turn else { return c }
        let track = t.runId.flatMap { runs[$0] }
        c.conversationId = t.conversationId ?? track?.conversationId
        c.turnId = t.id; c.runId = t.runId; c.taskId = t.taskId; c.origin = t.origin; c.providerId = track?.providerId
        c.speech = (t.outcome == nil && speechTurn == t.id) ? speech : .off
        let active = track.map { $0.terminal == nil } ?? false
        c.phase = Self.phase(t, track, mic: mic, speech: c.speech)
        if c.phase == .working { c.operation = track?.openTools.last?.operation }
        c.answering = active && (track?.answering ?? false) && t.outcome == nil
        c.connectivity = active ? (track?.connectivity ?? .live) : .live
        c.progress = active ? track?.progress : nil
        if let track {
            let (intent, intensity, index) = Self.intent(t, track, phase: c.phase)
            c.intent = intent; c.intensity = intensity; c.segment = index
            c.intentSource = intent == .neutral ? .none : .model
        }
        return c
    }

    private static func phase(_ t: Turn, _ track: Track?, mic: CompanionAudio, speech: CompanionAudio) -> CompanionPhase {
        if let outcome = t.outcome { return outcome }
        if t.voice == .confirming { return .awaitingApproval }
        let running = track.map { $0.terminal == nil } ?? false
        if running, let track, track.state == .awaitingApproval || !track.pendingApprovals.isEmpty { return .awaitingApproval }
        if speech.availability == .live { return .speaking }
        if running, let track { return track.openTools.isEmpty ? .thinking : .working }
        if !t.hasVoiceLayer { return track == nil ? .idle : .thinking }
        switch t.voice {
        case .preparing: return mic.availability == .preparing ? .preparing : .idle
        case .listening: return mic.availability == .live ? .listening : .preparing
        case .finalizing: return .transcribing
        case .thinking, .synthesizing, .speaking: return .thinking
        case .confirming: return .awaitingApproval
        case .idle, .interrupted, .failed: return .idle
        }
    }

    /// The declared expression of the segment being shown (text turns) or spoken (spoken turns), overruled by runtime truth.
    private static func intent(_ t: Turn, _ track: Track, phase: CompanionPhase) -> (CompanionIntent, Double?, Int?) {
        guard !track.segments.isEmpty else { return (.neutral, nil, nil) }
        let current: SegmentRecord?
        if t.spoken {
            guard let start = t.chunkStart else { return (.neutral, nil, nil) }
            current = track.segments.last { $0.plainStart <= start }
        } else {
            current = track.segments.last
        }
        guard let seg = current else { return (.neutral, nil, nil) }
        let effective = clamp(seg.intent, track, phase)
        return (effective, effective == .neutral ? nil : seg.intensity, seg.index)
    }

    /// Runtime truth over expressive intent.
    private static func clamp(_ i: CompanionIntent, _ track: Track, _ phase: CompanionPhase) -> CompanionIntent {
        if i == .neutral { return .neutral }
        switch phase {
        case .failed, .cancelled, .interrupted: return .neutral
        case .awaitingApproval: return i == .cautious || i == .focused ? i : .neutral
        case .idle, .preparing, .listening, .transcribing, .working: return .neutral
        case .thinking: if !track.answering { return .neutral }
        case .speaking, .completed: break
        }
        let unfulfilled = track.failed + track.declined > 0
        switch i {
        case .celebrating: return track.terminal == .completed && !unfulfilled ? i : .neutral
        case .playful: return unfulfilled ? .neutral : i
        default: return i
        }
    }
}
