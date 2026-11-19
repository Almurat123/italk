import Foundation

/// The one authoritative voice-conversation state. A session spans many turns: listening → endOfTurn → processing →
/// speaking → listening …, until the user ends it, the OS interrupts it, or it idles out. Individual agent runs and TTS
/// utterances never end the session by finishing.
public struct VoiceSessionCoordinator: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case listening(turn: Int)
        case detectingEndOfTurn(turn: Int)
        case processing(turn: Int)
        case speaking(turn: Int)
        /// Session kept but microphone off (no speech for a while, app backgrounded). Tap to resume.
        case paused(PauseReason)
        /// Audio interruption (call, Siri, another app). Never auto-resumes the microphone.
        case interrupted
        case error(String)
    }
    public enum PauseReason: String, Sendable, Equatable { case noSpeech, background, user, routeChange }

    public enum Event: Sendable, Equatable {
        case start
        case userStop
        case speechDetected
        case endOfTurnCandidate
        case turnCommitted
        case noSpeech
        case answerReady(willSpeak: Bool)
        case playbackFinished
        case processingFailed(String)
        case interruptionBegan
        case interruptionEnded
        case routeChanged
        case backgrounded
        case resume
        case tapWhileSpeaking
        /// The user paused the session (central control). Everything stops; the next tap resumes.
        case userPause
        /// Genuine user speech while the assistant was thinking or speaking: the old answer is abandoned, a new turn begins
        /// on the same (already running) capture.
        case bargeIn
    }

    public enum Effect: Sendable, Equatable {
        case startListening(session: UUID, turn: Int)
        case stopListening
        case commitTurn(session: UUID, turn: Int)
        case stopSpeaking
        case none
    }

    public private(set) var state: State = .idle
    public private(set) var sessionId = UUID()
    public private(set) var turn = 0
    /// Consecutive listens that heard nothing; two in a row pause the session (battery, privacy).
    public private(set) var emptyListens = 0
    public static let maxEmptyListens = 2

    public init() {}

    public var isActive: Bool {
        switch state { case .idle, .paused, .interrupted, .error: false; default: true }
    }

    /// Applies an event and returns the side effect the host must perform. Pure: no audio, no timers.
    public mutating func handle(_ event: Event) -> Effect {
        switch (event, state) {
        case (.start, _), (.resume, .paused), (.resume, .interrupted):
            // Start is always honoured (also from a state left behind by an external cancel); a new session id only when
            // there was no live session, so in-flight callbacks of an active session still match.
            switch state { case .idle, .error: sessionId = UUID(); default: break }
            emptyListens = 0
            return listen()
        case (.userPause, _) where isActive || state == .interrupted:
            state = .paused(.user); return .stopListening
        case (.bargeIn, .processing), (.bargeIn, .speaking):
            return listen()
        case (.userStop, _):
            let wasSpeaking: Bool = if case .speaking = state { true } else { false }
            state = .idle
            return wasSpeaking ? .stopSpeaking : .stopListening
        case (.speechDetected, .listening(let t)):
            emptyListens = 0; state = .listening(turn: t); return .none
        case (.endOfTurnCandidate, .listening(let t)):
            state = .detectingEndOfTurn(turn: t); return .none
        case (.speechDetected, .detectingEndOfTurn(let t)):
            state = .listening(turn: t); return .none                      // the user went on talking
        case (.turnCommitted, .listening(let t)), (.turnCommitted, .detectingEndOfTurn(let t)):
            emptyListens = 0; state = .processing(turn: t); return .commitTurn(session: sessionId, turn: t)
        case (.noSpeech, .listening), (.noSpeech, .detectingEndOfTurn):
            emptyListens += 1
            if emptyListens >= Self.maxEmptyListens { state = .paused(.noSpeech); return .stopListening }
            return listen()
        case (.answerReady(let willSpeak), .processing(let t)):
            if willSpeak { state = .speaking(turn: t); return .none }
            return listen()                                                // text-only answer: straight back to listening
        case (.playbackFinished, .speaking):
            return listen()                                                // the core rule: playback end re-arms the mic
        case (.tapWhileSpeaking, .speaking), (.tapWhileSpeaking, .processing):
            return listen()                                                // host stops audio/run first: starting to listen always cancels output
        case (.processingFailed(let m), .processing):
            state = .error(m); return .stopListening
        case (.interruptionBegan, _) where isActive:
            state = .interrupted; return .stopListening
        case (.interruptionEnded, .interrupted):
            return .none                                                   // stay interrupted: the user taps to continue
        case (.routeChanged, _) where isActive:
            state = .paused(.routeChange); return .stopListening
        case (.backgrounded, _) where isActive:
            state = .paused(.background); return .stopListening
        default:
            return .none                                                   // stale or irrelevant event: ignored
        }
    }

    private mutating func listen() -> Effect {
        turn += 1
        state = .listening(turn: turn)
        return .startListening(session: sessionId, turn: turn)
    }

    /// True when a callback tagged with (session, turn) still belongs to the current turn.
    public func isCurrent(session: UUID, turn t: Int) -> Bool { session == sessionId && t == turn }
}

/// Which action the central voice control performs right now. Codex renders icon/label from this; the model performs it.
public enum VoiceControlAction: String, Sendable, Equatable {
    case start      // idle / paused / interrupted / failed → start or resume the voice session
    case submit     // listening with words → commit this turn now
    case pause      // listening, nothing said yet → pause the session (mic off)
    case stop       // thinking / speaking / preparing → stop everything immediately and pause the session
}

/// Per-turn event log with monotonic timestamps (`ProcessInfo.systemUptime`). Numbers and event names only; no text, no audio.
public struct VoiceTimeline: Sendable, Equatable {
    public enum Event: String, Sendable, CaseIterable {
        case listen_started, last_user_speech, turn_committed, llm_started, first_llm_token, first_stable_phrase, tts_synthesis_started,
             first_pcm_ready, first_audio_played, llm_completed, playback_completed, user_barge_in_detected, old_audio_stopped,
             new_asr_partial, stop_button_tapped, session_ui_stopped, inference_cancel_completed,
             capture_requested, mic_running, first_audio_buffer, recognizer_ready, first_text
    }
    public var sessionId: UUID?
    public var turn: Int = 0
    public private(set) var events: [String: Double] = [:]
    public var footprintMB: Int?
    public var echoCancellation: Bool?
    public var route: String?
    public init() {}

    /// Records the first occurrence of an event (later ones are ignored unless `overwrite`).
    public mutating func mark(_ e: Event, at t: Double = ProcessInfo.processInfo.systemUptime, overwrite: Bool = false) {
        if overwrite || events[e.rawValue] == nil { events[e.rawValue] = t }
    }
    public func time(_ e: Event) -> Double? { events[e.rawValue] }

    /// One JSON line: milliseconds relative to `last_user_speech` (or the earliest event), plus ids and context.
    public func jsonLine() -> String? {
        guard let ref = time(.last_user_speech) ?? events.values.min() else { return nil }
        var parts = ["\"session\":\"\(sessionId?.uuidString.prefix(8) ?? "-")\"", "\"turn\":\(turn)", "\"uptime\":\(Int(ref))"]
        for e in Event.allCases { if let t = time(e) { parts.append("\"\(e.rawValue)\":\(Int(((t - ref) * 1000).rounded()))") } }
        if let footprintMB { parts.append("\"footprintMB\":\(footprintMB)") }
        if let echoCancellation { parts.append("\"echoCancellation\":\(echoCancellation)") }
        if let route { parts.append("\"route\":\"\(route)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

/// Splits one continuous session transcript (capture keeps running across turns) into per-turn text.
public struct TranscriptSegmenter: Sendable, Equatable {
    public private(set) var offset = 0
    public init() {}
    /// Start the next turn after everything heard so far.
    public mutating func beginTurn(full: String) { offset = full.count }
    /// Start the next turn at a known character position (barge-in: where the interrupting speech began).
    public mutating func beginTurn(at position: Int) { offset = max(0, position) }
    /// Keep the current offset (e.g. a barge-in: the interrupting words are already after it).
    public func turnText(_ full: String) -> String {
        // ASR may revise and shorten earlier text; never index past the end.
        let start = min(offset, full.count)
        // A late final of the previous turn can add its punctuation after the cut; never start a turn with it.
        return String(String(full.dropFirst(start)).drop { "，。！？、；：,.!?;: ".contains($0) })
    }
}

/// Decides whether speech heard while the assistant is thinking/speaking is a genuine interruption.
public struct BargeInDetector: Sendable {
    public enum Verdict: Equatable, Sendable { case none, echo, backchannel, interrupt }
    static let backchannels: Set<String> = ["嗯", "嗯嗯", "好", "好的", "对", "对对", "是", "是的", "哦", "噢", "啊", "行", "嗯好", "ok", "OK"]
    public var minimumWords = 2
    public init() {}

    /// - Parameters:
    ///   - heard: text recognized since the user's last committed turn.
    ///   - assistantSpeech: what the assistant has said aloud (or is about to), for echo rejection.
    ///   - voiceRecentlyActive: VAD saw speech within the last ~600 ms (rules out late ASR revisions of the previous turn).
    public func evaluate(heard: String, assistantSpeech: String, voiceRecentlyActive: Bool) -> Verdict {
        let w = MandarinCompletion.words(heard)
        guard voiceRecentlyActive, w.count >= minimumWords else { return .none }
        if Self.backchannels.contains(w) { return .backchannel }
        // Residual echo: the recognized words are (mostly) a substring of what the assistant said.
        let said = MandarinCompletion.words(assistantSpeech)
        if !said.isEmpty {
            if said.contains(w) { return .echo }
            let overlap = Self.bigramOverlap(w, said)
            if overlap >= 0.6 { return .echo }
        }
        return .interrupt
    }

    static func bigramOverlap(_ a: String, _ b: String) -> Double {
        let ac = Array(a), bc = Array(b)
        guard ac.count >= 2 else { return bc.contains(ac.first ?? " ") ? 1 : 0 }
        var bs = Set<String>()
        for i in 0..<max(0, bc.count - 1) { bs.insert(String(bc[i...i+1])) }
        var hit = 0
        for i in 0..<(ac.count - 1) where bs.contains(String(ac[i...i+1])) { hit += 1 }
        return Double(hit) / Double(ac.count - 1)
    }
}
