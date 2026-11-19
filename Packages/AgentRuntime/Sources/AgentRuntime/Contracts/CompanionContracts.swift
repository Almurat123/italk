import Foundation

// MARK: - Companion signals (what the character may know about the assistant)
//
// One small, provider-independent snapshot per change of state. Every field is derived from something that really happened
// (a run event, a microphone buffer, an audio frame that was played), never from the wording of an answer.
//
// - `phase` never claims more than is true: `preparing` until audio actually flows, `awaitingApproval` is never `working`,
//   `speaking` only while synthesized audio is audible, an outcome is released once and everything of that turn after it is dropped.
// - Levels are measured: `level == nil` means "there is no signal source" (system voice, microphone not attended), `0` means
//   measured silence.
// - `intent` is optional model-declared expression for the answer segment being shown or spoken. It is `.neutral` whenever the
//   model declared nothing, declared something unknown, or the runtime state contradicts it (a failed tool never celebrates).
//   It is transient: it is not persisted, not logged with content and never describes the person.
// - `progress` stays nil unless a producer really reports a fraction (none does today).

public enum CompanionPhase: String, Codable, Sendable, CaseIterable {
    /// Nothing is happening and nothing is expected from the person.
    case idle
    /// The person asked to talk but audio is not flowing yet (microphone starting, recognizer preparing). Not listening yet.
    case preparing
    /// The microphone delivers audio and the assistant attends to it.
    case listening
    /// The person stopped speaking; the transcript is being finalized.
    case transcribing
    /// A model is producing its next step or its answer; no tool executes and nothing waits for the person.
    case thinking
    /// A tool is actually executing (see `operation`).
    case working
    /// Something needs the person's decision and nothing executes meanwhile.
    case awaitingApproval
    /// Synthesized speech is audibly playing (the first audio has been played, playback has not ended).
    case speaking
    // Outcomes: released once per turn, sticky until the next activity or `settle`.
    case completed, interrupted, cancelled, failed

    public var isOutcome: Bool { self == .completed || self == .interrupted || self == .cancelled || self == .failed }
}

/// Expression the model declared for a segment of its own answer. Describes how the reply sounds, never the person's state.
public enum CompanionIntent: String, Codable, Sendable, CaseIterable {
    case neutral, curious, focused, explaining, encouraging, comforting, playful, celebrating, apologetic, cautious, uncertain
}

/// Category of the work a tool really performs, from a fixed table over the tool's declared capability and side effect.
public enum CompanionOperation: String, Codable, Sendable, CaseIterable {
    case lookup, read, write, communicate, control, compute, remember, skill, other

    /// Fixed mapping. Never derived from text.
    public static func of(_ capability: Capability, hasSideEffect: Bool) -> CompanionOperation {
        if hasSideEffect {
            switch capability {
            case .communication: return .communicate
            case .calendar, .reminders, .files, .documents, .photos, .contacts, .clipboard: return .write
            case .alarms, .home, .media, .audio, .apps, .shortcuts, .device, .bluetooth, .nfc, .notifications, .widgets, .liveActivities, .watch,
                 .camera, .sensors: return .control
            case .memory, .history: return .remember
            default: return .other
            }
        }
        switch capability {
        case .web, .weather, .maps, .network, .spotlight, .thirdPartySkills: return .lookup
        case .datetime, .calculator, .translation, .language, .vision: return .compute
        case .memory, .history: return .remember
        case .runtime: return .skill
        case .cloudPersonalData, .cloudHealthData: return .other
        default: return .read
        }
    }
}

/// Where the runtime state of this cue came from.
public enum CompanionOrigin: String, Codable, Sendable, CaseIterable {
    /// Microphone / recognizer / playback pipeline, before or without an agent run.
    case voice
    /// An agent run on a model on this device.
    case localAgent
    /// An agent run on iTalk's cloud models.
    case cloudAgent
    /// A task executing on the person's Mac.
    case macAgent
}

public enum CompanionConnectivity: String, Codable, Sendable, CaseIterable {
    case live
    /// The model or task connection dropped and is being re-established; nothing is progressing until it returns.
    case reconnecting
    /// Parked on purpose (app left the foreground, run suspended).
    case paused
}

public enum CompanionIntentSource: String, Codable, Sendable, CaseIterable {
    /// No expression was declared (or the runtime overruled it): the character uses the runtime state alone.
    case none
    /// The model declared it with a segment tone tag (`ToneProtocol`).
    case model
}

/// Why a turn ended early. Carried in `CompanionCue.detail` of interruption/cancellation cues.
public enum CompanionCause: String, Codable, Sendable, CaseIterable {
    case userSpeech = "user_speech", userTap = "user_tap", userStop = "user_stop", superseded
    case systemAudio = "system_audio", routeChange = "route_change", background, error, expired
}

public enum CompanionEventKind: String, Codable, Sendable, CaseIterable {
    /// State changed without a discrete event (a flag, the answer started streaming, an intent was re-evaluated).
    case snapshot
    case turnStarted, phaseChanged
    case userSpeechStarted, userSpeechEnded
    case segmentStarted
    case toolStarted, toolSucceeded, toolFailed
    case approvalRequested, approvalResolved
    case speechStarted, speechEnded
    case interrupted, cancelled, failed, completed
    case reconnecting, resumed
    case modelSwitched
    /// Only a microphone or playback level moved (throttled, ≤ 30 per second).
    case level
}

/// A microphone or playback signal.
public struct CompanionAudio: Codable, Sendable, Equatable {
    public enum Availability: String, Codable, Sendable {
        /// No stream.
        case off
        /// Starting (microphone / recognizer warming up, speech being synthesized): no samples yet.
        case preparing
        /// Samples are flowing. `level == 0` is real silence.
        case live
    }
    public var availability: Availability
    /// 0…1. nil: there is no measurable signal (not live, a source that cannot be metered such as the system voice, or a microphone
    /// that is open but not being attended to).
    public var level: Double?
    /// Microphone: the person is speaking (debounced voice activity). Speech: audio is audibly playing right now.
    public var active: Bool

    public init(availability: Availability = .off, level: Double? = nil, active: Bool = false) {
        self.availability = availability; self.level = level; self.active = active
    }
    public static let off = CompanionAudio()
}

public struct CompanionCue: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    /// Strictly increasing within one hub (process lifetime). A consumer applies cues in order and drops any with a lower number.
    public var sequence: Int
    public var timestamp: Date

    // Identity of what the cue is about. All nil while idle.
    public var conversationId: UUID?
    /// The user turn (the voice session generation / the user message) this belongs to.
    public var turnId: UUID?
    /// The agent run, when there is one (nil before the run exists, and for turns without a model).
    public var runId: UUID?
    /// The Mac agent's task id for remote tasks.
    public var taskId: String?
    public var origin: CompanionOrigin
    /// The model provider serving the current step (the cloud model, an on-device model…).
    public var providerId: String?

    // Runtime truth.
    public var phase: CompanionPhase
    /// What the running tool does. Only set while `phase == .working`.
    public var operation: CompanionOperation?
    /// 0…1 only when a producer really reported a fraction; nil otherwise (no producer does today).
    public var progress: Double?
    /// Answer text is streaming to the screen (silent). Distinct from `speaking`.
    public var answering: Bool
    public var connectivity: CompanionConnectivity
    public var mic: CompanionAudio
    public var speech: CompanionAudio

    // Optional semantic expression for the segment being shown/spoken.
    public var intent: CompanionIntent
    /// 0…1, nil when the model did not say.
    public var intensity: Double?
    /// Reliability of the intent. nil: not measured for this model (see docs/companion-cue-contract.md).
    public var confidence: Double?
    public var intentSource: CompanionIntentSource
    /// Index of the answer segment the intent belongs to (per model step).
    public var segment: Int?

    /// Why this cue was emitted.
    public var event: CompanionEventKind
    /// Failure code, interruption cause (`CompanionCause`) or tool operation, depending on `event`.
    public var detail: String?

    public var id: Int { sequence }

    public init(sequence: Int = 0, timestamp: Date = .now, conversationId: UUID? = nil, turnId: UUID? = nil, runId: UUID? = nil, taskId: String? = nil,
                origin: CompanionOrigin = .voice, providerId: String? = nil, phase: CompanionPhase = .idle, operation: CompanionOperation? = nil,
                progress: Double? = nil, answering: Bool = false, connectivity: CompanionConnectivity = .live, mic: CompanionAudio = .off,
                speech: CompanionAudio = .off, intent: CompanionIntent = .neutral, intensity: Double? = nil, confidence: Double? = nil,
                intentSource: CompanionIntentSource = .none, segment: Int? = nil, event: CompanionEventKind = .snapshot, detail: String? = nil) {
        self.schemaVersion = Self.schemaVersion
        self.sequence = sequence; self.timestamp = timestamp; self.conversationId = conversationId; self.turnId = turnId; self.runId = runId
        self.taskId = taskId; self.origin = origin; self.providerId = providerId; self.phase = phase; self.operation = operation
        self.progress = progress; self.answering = answering; self.connectivity = connectivity; self.mic = mic; self.speech = speech
        self.intent = intent; self.intensity = intensity; self.confidence = confidence; self.intentSource = intentSource; self.segment = segment
        self.event = event; self.detail = detail
    }

    /// Same state, ignoring when and why it was emitted.
    func sameState(as other: CompanionCue) -> Bool {
        var a = self, b = other
        a.sequence = 0; b.sequence = 0; a.timestamp = .distantPast; b.timestamp = .distantPast
        a.event = .snapshot; b.event = .snapshot; a.detail = nil; b.detail = nil
        return a == b
    }
}

/// Loudness normalization shared by the microphone tap and the playback tap, so both report on the same 0…1 scale.
public enum CompanionLevel {
    public static let micFloorDB = -55.0, micRangeDB = 45.0
    public static let speechFloorDB = -50.0, speechRangeDB = 44.0

    /// `rms` is the linear root-mean-square of one buffer (full scale = 1). `floorDB` maps to 0, `floorDB + rangeDB` to 1.
    public static func normalized(rms: Double, floorDB: Double, rangeDB: Double) -> Double {
        guard rms.isFinite, rms > 0, rangeDB > 0 else { return 0 }
        let db = 20 * log10(max(rms, 0.00001))
        return min(1, max(0, (db - floorDB) / rangeDB))
    }
    public static func mic(rms: Double) -> Double { normalized(rms: rms, floorDB: micFloorDB, rangeDB: micRangeDB) }
    public static func speech(rms: Double) -> Double { normalized(rms: rms, floorDB: speechFloorDB, rangeDB: speechRangeDB) }
    /// Clamps any externally supplied level into 0…1 (NaN → 0).
    public static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
