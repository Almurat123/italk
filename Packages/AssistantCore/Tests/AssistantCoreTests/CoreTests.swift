import Foundation
import Testing
@testable import AssistantCore

@Test func staleCallbacksAndPlaybackCannotBecomeTranscript() {
    var session = VoiceSession()
    let old = session.begin()
    let started = session.transition(.listening, for: old)
    #expect(started)
    session.cancel()
    let current = session.begin()
    let stale = session.transition(.speaking, for: old)
    #expect(!stale)
    session.receiveTranscript("old", for: old)
    #expect(session.transcript.isEmpty)
    let thinking = session.transition(.thinking, for: current)
    let speaking = session.transition(.speaking, for: current)
    #expect(thinking)
    #expect(speaking)
    session.receiveTranscript("assistant echo", for: current)
    #expect(session.transcript.isEmpty)
    let overlapping = session.transition(.listening, for: current)
    #expect(!overlapping)
}

@Test func speechSynthesisIsCancellableAndCannotRecordOrPlayAfterANewTurn() {
    var session = VoiceSession()
    let first = session.begin()
    let planned = session.transition(.thinking, for: first)
    let synthesizing = session.transition(.synthesizing, for: first)
    let recording = session.transition(.listening, for: first)
    #expect(planned && synthesizing && !recording)
    session.cancel()
    let next = session.begin()
    let stale = session.transition(.speaking, for: first)
    let replanned = session.transition(.thinking, for: next)
    let resynthesizing = session.transition(.synthesizing, for: next)
    let speaking = session.transition(.speaking, for: next)
    let finished = session.transition(.idle, for: next)
    #expect(!stale && replanned && resynthesizing && speaking && finished)
}

@Test func characterAttentionReturnsForwardWithoutAnUnbrokenStare() {
    let points = (0..<1400).map { CharacterGaze.sample(at: Double($0) / 100) }
    let forward = points.filter { abs($0.x) < 0.08 && abs($0.y) < 0.08 }.count
    #expect(Double(forward) / Double(points.count) > 0.70)
    #expect(Double(forward) / Double(points.count) < 0.95)
    #expect(points.allSatisfy { abs($0.x) < 0.36 && abs($0.y) < 0.27 })
    #expect(points.contains { $0.x < -0.20 })
    #expect(points.contains { $0.x > 0.20 })
    #expect(CharacterGaze.sample(at: .nan).x == 0)
}

@Test func sleepUnionDoesNotCountInBedOrImportsTwice() {
    let start = Date(timeIntervalSince1970: 0)
    func sample(_ a: Double, _ b: Double, _ stage: SleepInterval.Stage) -> SleepInterval {
        .init(start: start.addingTimeInterval(a), end: start.addingTimeInterval(b), stage: stage, source: "fixture")
    }
    let samples = [sample(0, 100, .inBed), sample(10, 40, .core), sample(10, 40, .asleep), sample(40, 70, .deep), sample(65, 80, .rem), sample(80, 90, .awake), sample(100, 90, .asleep)]
    #expect(HealthMath.sleepDuration(samples, within: .init(start: start, duration: 100)) == 70)
    #expect(HealthMath.sleepDuration(samples, within: .init(start: start.addingTimeInterval(20), duration: 30)) == 30)
}

@Test func missingDaysAreNotZeroAndDoNotEstablishATrend() {
    #expect(HealthMath.mean([1, nil, 2, nil, 3, nil, 4]) == nil)
    #expect(HealthMath.mean([10, 10, 10, 10, 10, nil, nil]) == 10)
}

@Test func unauthorizedCapabilitiesAreAbsent() {
    #expect(Skill.available(grants: []).map(\.id) == ["clock"])
    #expect(!Skill.available(grants: [.cloudAI]).contains { $0.id == "research" })
    #expect(Skill.available(grants: [.cloudAI, .research]).contains { $0.id == "research" })
}

@Test func confirmationsExpireAndMemoryEditsConflict() throws {
    let start = Date(timeIntervalSince1970: 0)
    let confirmation = Confirmation(title: "fixture", body: "fixture", now: start)
    #expect(!confirmation.valid(at: start.addingTimeInterval(60)))
    var record = MemoryRecord(content: "old", sensitive: false, sourceTurn: UUID(), now: start)
    try record.edit("new", expectedRevision: 1)
    #expect(throws: MemoryError.conflict) { try record.edit("stale", expectedRevision: 1) }
    #expect(record.content == "new")
    #expect(record.history.first?.content == "old")
}

@Test func quietHoursAcrossMidnight() {
    var policy = SuggestionPolicy(); policy.enabled = true
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = Date(timeIntervalSince1970: 0)
    #expect(!policy.permits(at: midnight.addingTimeInterval(23 * 3600), calendar: calendar, deliveredToday: 0))
    #expect(!policy.permits(at: midnight.addingTimeInterval(7 * 3600), calendar: calendar, deliveredToday: 0))
    #expect(policy.permits(at: midnight.addingTimeInterval(12 * 3600), calendar: calendar, deliveredToday: 0))
    #expect(!policy.permits(at: midnight.addingTimeInterval(12 * 3600), calendar: calendar, deliveredToday: 1))
}

@Test func consolidationStagesOnlyExplicitNonSensitiveCandidates() {
    let entries = [HistoryEntry(id: UUID(), question: "记住我喜欢简短回答", answer: ""), HistoryEntry(id: UUID(), question: "记住我喜欢简短回答", answer: ""), HistoryEntry(id: UUID(), question: "记住我的血压偏高", answer: ""), HistoryEntry(id: UUID(), question: "我喜欢音乐", answer: "")]
    let candidates = MemoryReview.candidates(from: entries, existing: [])
    #expect(candidates.count == 2)
    #expect(candidates[0].content == "我喜欢简短回答")
}

@Test func holdToTalkCancellationAndNewGestureReset() {
    var gesture = HoldToTalkInteraction()
    let inactive = gesture.end(); #expect(!inactive)
    gesture.begin(); gesture.move(horizontal: 0, vertical: -100)
    #expect(gesture.willCancel)
    let upward = gesture.end(); #expect(!upward)
    gesture.begin(); gesture.move(horizontal: -90, vertical: 0)
    let sideways = gesture.end(); #expect(!sideways)
    gesture.begin(); gesture.move(horizontal: 0, vertical: -90)
    gesture.move(horizontal: 0, vertical: 0)
    let restored = gesture.end(); #expect(restored)
    #expect(!gesture.active && !gesture.willCancel)
}

@Test func releaseDuringCapturePreparationIsRemembered() {
    var intent = CaptureIntent(delivery: .dictation, held: true)
    intent.release()
    #expect(intent.finishRequested && intent.held && intent.delivery == .dictation)
    intent = CaptureIntent(delivery: .dictation, held: true)
    #expect(!intent.finishRequested)
}
