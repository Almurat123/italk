import Foundation
import Testing
@testable import AssistantCore

@Test func completionHeuristicHandlesHesitationAndQuestions() {
    #expect(MandarinCompletion.assess("我昨天晚上……嗯……大概十二点睡觉，然后早上……") == .hesitating)
    #expect(MandarinCompletion.assess("我昨天晚上嗯") == .hesitating)
    #expect(MandarinCompletion.assess("帮我") == .incomplete)
    #expect(MandarinCompletion.assess("明天下午三点，不对") == .incomplete)
    #expect(MandarinCompletion.assess("今天天气怎么样") == .complete)
    #expect(MandarinCompletion.assess("你觉得这样可以吗") == .complete)
    #expect(MandarinCompletion.assess("提醒我明天开会") == .neutral)
    // ASR punctuation is not evidence: a pause-inserted 「。」 or 「？」 changes nothing.
    #expect(MandarinCompletion.assess("我昨天晚上。") == .incomplete)
    #expect(MandarinCompletion.assess("提醒我明天开会？") == .neutral)
}

/// Simulates the example utterance with real pause lengths and checks the detector never ends the turn early.
@Test func doesNotInterruptNaturalMandarinPauses() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = TurnDetector(start: t0)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    // speak "我昨天晚上" 0.0–1.2
    d.voice(active: true, at: at(0.1)); d.transcript("我昨天晚上", at: at(1.0)); d.voice(active: false, at: at(1.2))
    // 1.5 s hesitation
    for s in stride(from: 1.3, through: 2.7, by: 0.1) { #expect(d.decide(at: at(s)) == .listening, "cut off at \(s)") }
    d.voice(active: true, at: at(2.7)); d.transcript("我昨天晚上……嗯", at: at(2.9)); d.voice(active: false, at: at(3.0))
    // 2.0 s pause after a filler
    for s in stride(from: 3.1, through: 5.0, by: 0.1) { #expect(d.decide(at: at(s)) == .listening, "cut off after filler at \(s)") }
    d.voice(active: true, at: at(5.0)); d.transcript("我昨天晚上……嗯……大概十二点睡觉，然后早上", at: at(6.5)); d.voice(active: false, at: at(6.7))
    for s in stride(from: 6.8, through: 8.2, by: 0.1) { #expect(d.decide(at: at(s)) == .listening, "cut off at dangling 然后 at \(s)") }
    d.voice(active: true, at: at(8.2)); d.transcript("我昨天晚上……嗯……大概十二点睡觉，然后早上七点起床了", at: at(9.6)); d.voice(active: false, at: at(9.8))
    // Sentence complete: ends reasonably soon, but adapted to this speaker's long pauses.
    guard case .endOfTurn = d.decide(at: at(9.8 + d.requiredSilence() + 0.05)) else { Issue.record("should end after a complete sentence"); return }
    #expect(d.requiredSilence() >= 0.55 && d.requiredSilence() <= 2.5)
}

@Test func endsQuicklyOnACompleteShortQuestion() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = TurnDetector(start: t0)
    d.voice(active: true, at: t0); d.transcript("现在几点了", at: t0.addingTimeInterval(1)); d.voice(active: false, at: t0.addingTimeInterval(1.1))
    #expect(d.decide(at: t0.addingTimeInterval(1.5)) == .listening)
    guard case .endOfTurn = d.decide(at: t0.addingTimeInterval(1.7)) else { Issue.record("should end ~0.55 s after a complete question"); return }
}

/// Root cause of the slow endpoint: ASR finalization revises the text after the user stopped. Revisions without new words
/// must not restart the silence clock.
@Test func asrFinalizationRevisionsDoNotDelayTheTurn() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = TurnDetector(start: t0)
    d.voice(active: true, at: t0); d.transcript("明天杭州天气怎么样", at: t0.addingTimeInterval(1.2)); d.voice(active: false, at: t0.addingTimeInterval(1.3))
    d.transcript("明天杭州天气怎么样？", at: t0.addingTimeInterval(2.4))        // late punctuation/finalization
    guard case .endOfTurn = d.decide(at: t0.addingTimeInterval(1.9)) else { Issue.record("revision must not hold the turn"); return }
}

@Test func newWordsAfterAPauseKeepListening() {
    let t0 = Date(timeIntervalSince1970: 0)
    var d = TurnDetector(start: t0)
    d.voice(active: true, at: t0); d.transcript("我想订", at: t0.addingTimeInterval(0.8)); d.voice(active: false, at: t0.addingTimeInterval(0.9))
    // VAD missed the restart but ASR produced new words: that is speech.
    d.transcript("我想订明天的", at: t0.addingTimeInterval(1.6))
    #expect(d.decide(at: t0.addingTimeInterval(2.4)) == .listening)
}

@Test func noSpeechAndMaxDuration() {
    let t0 = Date(timeIntervalSince1970: 0)
    let d = TurnDetector(start: t0)
    #expect(d.decide(at: t0.addingTimeInterval(7)) == .listening)
    #expect(d.decide(at: t0.addingTimeInterval(8.1)) == .noSpeech)
    var e = TurnDetector(start: t0); e.voice(active: true, at: t0); e.transcript("一直说", at: t0)
    #expect(e.decide(at: t0.addingTimeInterval(61)) == .maxDuration)
}

@Test func energyVADAdaptsToNoise() {
    var v = EnergyVAD()
    for _ in 0..<30 { _ = v.process(levelDB: -45) }                  // noisy room
    let quiet = v.process(levelDB: -44)
    #expect(!quiet)
    _ = v.process(levelDB: -25)
    let speech = v.process(levelDB: -24)                              // speech 20 dB above floor (onset 2 frames)
    #expect(speech)
    for _ in 0..<5 { _ = v.process(levelDB: -46) }
    #expect(!v.active)
}

@Suite struct EnglishAndMixedEndingTests {
    @Test func englishUtterancesThatTrailOffAreIncomplete() {
        for s in ["I want to set an alarm for", "remind me to", "can you tell me about the", "I was thinking maybe we could", "set a timer and", "call my", "um", "so um", "Show me the weather in"] {
            #expect(MandarinCompletion.assess(s) != .complete && MandarinCompletion.assess(s) != .neutral, "should wait: \(s)")
        }
        #expect(MandarinCompletion.assess("um") == .incomplete || MandarinCompletion.assess("um") == .hesitating)
        #expect(MandarinCompletion.assess("so um…") == .hesitating)
    }

    @Test func englishRequestsThatEndCleanlyAreComplete() {
        for s in ["set an alarm for seven tomorrow", "what's the weather today", "turn off the lights please", "thanks a lot", "play some music now"] {
            #expect(MandarinCompletion.assess(s) == .complete || MandarinCompletion.assess(s) == .neutral, "should answer: \(s)")
        }
        #expect(MandarinCompletion.assess("turn off the lights please") == .complete)
    }

    @Test func wholeWordsOnlyNotSuffixes() {
        // "understand" ends in "and", "brand" in "and", "phone" in "one": none of them is a connector.
        for s in ["yes I understand", "that is a nice brand", "I lost my phone"] { #expect(MandarinCompletion.assess(s) != .incomplete, "\(s)") }
    }

    @Test func mixedChineseEnglishFollowsWhicheverLanguageTheSentenceEndsIn() {
        #expect(MandarinCompletion.assess("帮我 set an alarm for") == .incomplete)
        #expect(MandarinCompletion.assess("这个 meeting 改到下午三点了") == .complete)
        #expect(MandarinCompletion.assess("明天的 meeting 是几点") == .complete)
        #expect(MandarinCompletion.assess("帮我把 slides 发给") == .incomplete)
    }

    @Test func theDetectorWaitsLongerAfterAnUnfinishedEnglishSentence() {
        var d = TurnDetector(start: Date(timeIntervalSince1970: 0))
        d.voice(active: true, at: Date(timeIntervalSince1970: 1)); d.transcript("remind me to", at: Date(timeIntervalSince1970: 1.2)); d.voice(active: false, at: Date(timeIntervalSince1970: 1.5))
        #expect(d.decide(at: Date(timeIntervalSince1970: 2.5)) == .listening, "one second of silence after \"remind me to\" is not the end of the turn")
        var e = TurnDetector(start: Date(timeIntervalSince1970: 0))
        e.voice(active: true, at: Date(timeIntervalSince1970: 1)); e.transcript("what's the weather today", at: Date(timeIntervalSince1970: 1.2)); e.voice(active: false, at: Date(timeIntervalSince1970: 1.5))
        if case .endOfTurn = e.decide(at: Date(timeIntervalSince1970: 2.2)) {} else { Issue.record("a finished English question should end the turn after ~0.5s of silence") }
    }
}
