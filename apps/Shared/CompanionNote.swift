import Foundation
import AssistantCore

/// What the voice pipeline reports to the iPhone's companion hub (`apps/iOS/CompanionSignalHub.swift`). Plain notifications taken at the
/// places where something really happened (a measured microphone buffer, a played audio frame, the voice session changing phase);
/// no state machine lives here and nothing is derived from text. Compiled on the watch too, where `AppModel.companion` stays nil.
enum CompanionNote {
    enum Mic { case preparing, live, off }

    /// `AppModel.session` changed phase or generation (turn). `spoken`: the answer of this turn is to be read aloud.
    case session(old: VoiceSession, new: VoiceSession, conversation: UUID?, spoken: Bool)
    case mic(Mic)
    /// One measured microphone buffer, 0…1 (never an artificial reset to zero).
    case micLevel(Double)
    /// Debounced voice activity of the person (the end-of-turn timer's view).
    case micVoice(Bool)
    /// One measured playback buffer, 0…1.
    case speechLevel(Double)
    /// Speech for `turn` is being synthesized; no audio yet.
    case speechPreparing(turn: UUID)
    /// The chunk whose source starts at `sourceStart` (characters of the plain answer text) began playing.
    case speechChunk(turn: UUID, sourceStart: Int)
    /// Playback of `turn` was cut short. `cause` is a `CompanionCause` raw value.
    case speechStopped(turn: UUID, cause: String)
    /// Why the turn that is about to be replaced or stopped ends (`CompanionCause` raw value). Consumed by the next turn change.
    case endCause(String)
    /// The conversation on screen.
    case focus(conversation: UUID?)
}
