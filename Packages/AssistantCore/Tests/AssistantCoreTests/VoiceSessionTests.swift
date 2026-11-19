import Foundation
import Testing
@testable import AssistantCore

@Test func tenConsecutiveTurnsWithoutTapping() {
    var c = VoiceSessionCoordinator()
    guard case .startListening(let s, 1) = c.handle(.start) else { Issue.record("start"); return }
    for i in 1...10 {
        #expect(c.state == .listening(turn: i))
        _ = c.handle(.speechDetected); _ = c.handle(.endOfTurnCandidate)
        #expect(c.handle(.turnCommitted) == .commitTurn(session: s, turn: i))
        #expect(c.handle(.answerReady(willSpeak: true)) == .none)
        #expect(c.state == .speaking(turn: i))
        // TTS finishing re-arms the microphone automatically.
        #expect(c.handle(.playbackFinished) == .startListening(session: s, turn: i + 1))
    }
    #expect(c.isActive && c.sessionId == s)
}

@Test func silenceAfterAnswerPausesInsteadOfLoopingForever() {
    var c = VoiceSessionCoordinator()
    _ = c.handle(.start)
    #expect(c.handle(.noSpeech) == .startListening(session: c.sessionId, turn: 2))
    #expect(c.handle(.noSpeech) == .stopListening)
    #expect(c.state == .paused(.noSpeech) && !c.isActive)
    guard case .startListening = c.handle(.resume) else { Issue.record("resume"); return }
}

@Test func pausedAndResumedEndOfTurnCandidate() {
    var c = VoiceSessionCoordinator()
    _ = c.handle(.start); _ = c.handle(.endOfTurnCandidate)
    #expect(c.state == .detectingEndOfTurn(turn: 1))
    _ = c.handle(.speechDetected)                                    // user kept talking
    #expect(c.state == .listening(turn: 1))
}

@Test func interruptionsNeverAutoResumeTheMicrophone() {
    var c = VoiceSessionCoordinator()
    _ = c.handle(.start)
    #expect(c.handle(.interruptionBegan) == .stopListening)
    #expect(c.handle(.interruptionEnded) == .none && c.state == .interrupted)
    _ = c.handle(.resume)
    #expect(c.isActive)
    #expect(c.handle(.backgrounded) == .stopListening && c.state == .paused(.background))
}

@Test func staleCallbacksAreDetectable() {
    var c = VoiceSessionCoordinator()
    _ = c.handle(.start)
    let old = (c.sessionId, c.turn)
    _ = c.handle(.turnCommitted); _ = c.handle(.answerReady(willSpeak: false))   // text-only answer → next listen
    #expect(!c.isCurrent(session: old.0, turn: old.1))
    #expect(c.handle(.playbackFinished) == .none)                                  // not speaking: ignored
    #expect(c.handle(.userStop) == .stopListening && c.state == .idle)
}

@Test func pauseAndBargeInTransitions() {
    var c = VoiceSessionCoordinator()
    _ = c.handle(.start); _ = c.handle(.turnCommitted)
    #expect(c.handle(.bargeIn) == .startListening(session: c.sessionId, turn: 2))      // interrupt while thinking
    _ = c.handle(.turnCommitted); _ = c.handle(.answerReady(willSpeak: true))
    #expect(c.handle(.bargeIn) == .startListening(session: c.sessionId, turn: 3))      // interrupt while speaking
    #expect(c.handle(.userPause) == .stopListening && c.state == .paused(.user))
    #expect(c.handle(.playbackFinished) == .none, "a late completion must not resurrect a paused session")
    #expect(c.handle(.bargeIn) == .none)
    guard case .startListening = c.handle(.start) else { Issue.record("resume"); return }
}

@Test func segmenterSplitsContinuousTranscript() {
    var s = TranscriptSegmenter()
    s.beginTurn(full: "")
    #expect(s.turnText("明天天气怎么样") == "明天天气怎么样")
    s.beginTurn(full: "明天天气怎么样")
    #expect(s.turnText("明天天气怎么样？不对，我是问后天") == "不对，我是问后天")
    #expect(s.turnText("明天") == "")                                               // revision shrank the text
}

@Test func bargeInRejectsEchoBackchannelAndLateRevisions() {
    let d = BargeInDetector()
    let spoken = "明天杭州晴，最高气温二十五度，适合出门。"
    #expect(d.evaluate(heard: "最高气温二十五度", assistantSpeech: spoken, voiceRecentlyActive: true) == .echo)
    #expect(d.evaluate(heard: "嗯嗯", assistantSpeech: spoken, voiceRecentlyActive: true) == .backchannel)
    #expect(d.evaluate(heard: "那后天呢", assistantSpeech: spoken, voiceRecentlyActive: true) == .interrupt)
    #expect(d.evaluate(heard: "那后天呢", assistantSpeech: spoken, voiceRecentlyActive: false) == .none)   // ASR revision, no voice
    #expect(d.evaluate(heard: "等", assistantSpeech: spoken, voiceRecentlyActive: true) == .none)          // too little yet
}

@Test func timelineIsMonotonicAndTextFree() {
    var t = VoiceTimeline(); t.turn = 3
    t.mark(.last_user_speech, at: 100.0); t.mark(.turn_committed, at: 100.6); t.mark(.first_audio_played, at: 102.1); t.mark(.llm_completed, at: 102.9)
    t.mark(.turn_committed, at: 999)                                                     // first occurrence wins
    let line = t.jsonLine()!
    #expect(line.contains("\"turn_committed\":600") && line.contains("\"first_audio_played\":2100") && line.contains("\"llm_completed\":2900"))
}
