import Foundation
import Testing
@testable import AgentRuntime

private struct Session {
    var reducer = CompanionReducer(now: Date(timeIntervalSince1970: 100))
    var translator = CompanionVoiceTranslator()
    var turn = UUID(), phase = "idle"
    var conv = UUID()
    var cues: [CompanionCue] = []
    var clock = Date(timeIntervalSince1970: 100)

    var cue: CompanionCue { reducer.cue }

    /// What `AppModel.session`'s didSet reports for one mutation.
    mutating func move(to newPhase: String, newTurn: UUID? = nil, spoken: Bool = true, cause: CompanionCause? = nil) {
        let target = newTurn ?? turn
        for signal in translator.session(oldPhase: phase, oldTurn: turn, newPhase: newPhase, newTurn: target, conversation: conv, spoken: spoken, cause: cause) {
            clock = clock.addingTimeInterval(0.05)
            cues += reducer.apply(.voice(signal), at: clock)
        }
        turn = target; phase = newPhase
    }
    mutating func signal(_ s: CompanionVoiceSignal) { clock = clock.addingTimeInterval(0.05); cues += reducer.apply(.voice(s), at: clock) }
}

@Test func aNormalSpokenTurnIsTranslatedIntoItsPhases() {
    var s = Session()
    s.move(to: "idle", newTurn: UUID())             // session.cancel(): nothing was in flight
    #expect(s.cue.phase == .idle && s.cues.isEmpty)
    s.signal(.micPreparing)
    s.move(to: "preparing", newTurn: UUID())
    s.signal(.micLive)
    s.move(to: "listening")
    #expect(s.cue.phase == .listening)
    s.move(to: "finalizing"); s.move(to: "thinking")
    #expect(s.cue.phase == .transcribing || s.cue.phase == .thinking)
    s.move(to: "speaking")
    #expect(s.cue.phase == .speaking && s.cue.speech.availability == .live)
    s.move(to: "idle")
    #expect(s.cue.phase == .completed && s.cue.speech == .off)
}

@Test func aNewGenerationWhileSpeakingSilencesTheOldTurnFirst() {
    var s = Session()
    s.move(to: "preparing", newTurn: UUID()); s.signal(.micLive); s.move(to: "listening"); s.move(to: "thinking"); s.move(to: "speaking")
    let old = s.turn
    s.signal(.speechLevel(0.5))
    // The person talks over the answer: the app begins a new turn and says why.
    s.move(to: "preparing", newTurn: UUID(), cause: .userSpeech)
    let ended = s.cues.filter { $0.turnId == old }
    #expect(ended.contains { $0.event == .speechEnded && $0.detail == "user_speech" })
    #expect(ended.last?.phase == .interrupted && ended.last?.detail == "user_speech")
    #expect(s.cue.turnId == s.turn && s.cue.turnId != old && s.cue.speech == .off)
}

@Test func withoutAReasonAReplacedTurnCountsAsSuperseded() {
    var s = Session()
    s.move(to: "preparing", newTurn: UUID()); s.move(to: "thinking")
    let old = s.turn
    s.move(to: "idle", newTurn: UUID())             // session.cancel()
    #expect(s.cues.last(where: { $0.turnId == old })?.phase == .cancelled)
    #expect(s.cues.last(where: { $0.turnId == old })?.detail == "superseded")
    #expect(s.cue.phase == .cancelled, "the outcome stays until the next activity")
}

@Test func anIdleOrFailedTurnReplacedLaterEndsNothingTwice() {
    var s = Session()
    s.move(to: "preparing", newTurn: UUID()); s.move(to: "thinking"); s.move(to: "failed")
    #expect(s.cue.phase == .failed)
    let before = s.cues.count
    s.move(to: "idle", newTurn: UUID())             // cancel() after the failure
    #expect(s.cues.count == before, "a failed turn has already ended: nothing more to say")
}

@Test func unknownPhasesAreIdleAndRepeatsAreIgnored() {
    let t = CompanionVoiceTranslator()
    let turn = UUID()
    #expect(t.session(oldPhase: "thinking", oldTurn: turn, newPhase: "thinking", newTurn: turn, conversation: nil, spoken: false).isEmpty)
    let out = t.session(oldPhase: "thinking", oldTurn: turn, newPhase: "banana", newTurn: turn, conversation: nil, spoken: false)
    #expect(out == [.phase(.idle, turn: turn, conversation: nil, spoken: false)])
}
