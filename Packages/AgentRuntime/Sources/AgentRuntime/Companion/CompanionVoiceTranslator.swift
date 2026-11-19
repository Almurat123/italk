import Foundation

/// Turns changes of the app's voice session (phase + generation) into reducer signals, without this package knowing the session type:
/// phases travel as their raw values (`VoicePhase` and `CompanionVoicePhase` share them).
///
/// A new generation while the previous turn was still in flight means that turn ended without its normal ending (stopped, interrupted,
/// superseded); the app may say why (`cause`), otherwise it counts as superseded.
public struct CompanionVoiceTranslator: Sendable {
    public init() {}

    private static let inFlight: Set<CompanionVoicePhase> = [.preparing, .listening, .finalizing, .thinking, .synthesizing, .confirming, .speaking]

    public func session(oldPhase: String, oldTurn: UUID, newPhase: String, newTurn: UUID, conversation: UUID?, spoken: Bool,
                        cause: CompanionCause? = nil) -> [CompanionVoiceSignal] {
        let old = CompanionVoicePhase(rawValue: oldPhase) ?? .idle, new = CompanionVoicePhase(rawValue: newPhase) ?? .idle
        var out: [CompanionVoiceSignal] = []
        if oldTurn != newTurn {
            if Self.inFlight.contains(old) {
                let why = cause ?? .superseded
                out.append(.speechStopped(turn: oldTurn, cause: why))       // the audio goes dark with the turn, never after it
                out.append(.turnEnded(turn: oldTurn, cause: why))
            }
            out.append(.phase(new, turn: newTurn, conversation: conversation, spoken: spoken))
        } else if old != new {
            out.append(.phase(new, turn: newTurn, conversation: conversation, spoken: spoken))
        }
        return out
    }
}
