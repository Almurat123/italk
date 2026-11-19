import Foundation
import Testing
@testable import AgentRuntime

@Test func microphoneAndPlaybackLevelsKeepTheirExistingScales() {
    // The taps used `(db + 55) / 45` (microphone) and `(db + 50) / 44` (playback); the shared helper must not change what the character saw.
    for rms in [0.0005, 0.001, 0.003, 0.01, 0.03, 0.1, 0.3] {
        let db = 20 * log10(rms)
        #expect(abs(CompanionLevel.mic(rms: rms) - min(1, max(0, (db + 55) / 45))) < 1e-9)
        #expect(abs(CompanionLevel.speech(rms: rms) - min(1, max(0, (db + 50) / 44))) < 1e-9)
    }
}

@Test func silenceFullScaleAndGarbageNormalizeSafely() {
    #expect(CompanionLevel.mic(rms: 0) == 0)
    #expect(CompanionLevel.speech(rms: 0) == 0)
    #expect(CompanionLevel.mic(rms: 1) == 1)
    #expect(CompanionLevel.speech(rms: 4) == 1)
    #expect(CompanionLevel.mic(rms: .nan) == 0)
    #expect(CompanionLevel.mic(rms: .infinity) == 0)
    #expect(CompanionLevel.mic(rms: -0.5) == 0)
    #expect(CompanionLevel.mic(rms: 0.0000001) == 0)
    #expect(CompanionLevel.clamped(.nan) == 0)
    #expect(CompanionLevel.clamped(7) == 1)
    #expect(CompanionLevel.clamped(-3) == 0)
}

@Test func levelsRiseMonotonicallyWithLoudness() {
    var last = -1.0
    for i in 1...200 {
        let rms = Double(i) / 200
        let level = CompanionLevel.speech(rms: rms)
        #expect(level >= last)
        #expect((0...1).contains(level))
        last = level
    }
}

@Test func operationCategoriesComeFromAFixedTable() {
    #expect(CompanionOperation.of(.web, hasSideEffect: false) == .lookup)
    #expect(CompanionOperation.of(.weather, hasSideEffect: false) == .lookup)
    #expect(CompanionOperation.of(.calendar, hasSideEffect: false) == .read)
    #expect(CompanionOperation.of(.calendar, hasSideEffect: true) == .write)
    #expect(CompanionOperation.of(.reminders, hasSideEffect: true) == .write)
    #expect(CompanionOperation.of(.communication, hasSideEffect: true) == .communicate)
    #expect(CompanionOperation.of(.alarms, hasSideEffect: true) == .control)
    #expect(CompanionOperation.of(.home, hasSideEffect: true) == .control)
    #expect(CompanionOperation.of(.memory, hasSideEffect: false) == .remember)
    #expect(CompanionOperation.of(.calculator, hasSideEffect: false) == .compute)
    #expect(CompanionOperation.of(.runtime, hasSideEffect: false) == .skill)
    for capability in Capability.allCases {                    // total over every declared capability
        _ = CompanionOperation.of(capability, hasSideEffect: false)
        _ = CompanionOperation.of(capability, hasSideEffect: true)
    }
}

@Test func aCueSurvivesACodableRoundTripAndStaysVersioned() throws {
    let cue = CompanionCue(sequence: 12, timestamp: Date(timeIntervalSince1970: 1_000), conversationId: UUID(), turnId: UUID(), runId: UUID(),
                           origin: .cloudAgent, providerId: "iTalk.cloud", phase: .working, operation: .lookup, progress: nil, answering: false,
                           connectivity: .live, mic: CompanionAudio(availability: .live, level: 0.2, active: true),
                           speech: CompanionAudio(availability: .preparing), intent: .explaining, intensity: 0.6, intentSource: .model,
                           segment: 2, event: .toolStarted, detail: "lookup")
    let data = try JSONEncoder().encode(cue)
    let back = try JSONDecoder().decode(CompanionCue.self, from: data)
    #expect(back == cue)
    #expect(back.schemaVersion == 1)
    #expect(CompanionCue().phase == .idle)
    #expect(CompanionCue().mic == .off)
    #expect(CompanionCue().intent == .neutral)
    #expect(CompanionCue().intentSource == .none)
    #expect(CompanionCue().confidence == nil && CompanionCue().progress == nil)
}

@Test func sameStateIgnoresWhenAndWhy() {
    let a = CompanionCue(sequence: 1, timestamp: Date(timeIntervalSince1970: 1), phase: .thinking, event: .phaseChanged, detail: "x")
    var b = a
    b.sequence = 9; b.timestamp = Date(timeIntervalSince1970: 99); b.event = .snapshot; b.detail = nil
    #expect(a.sameState(as: b))
    b.phase = .working
    #expect(!a.sameState(as: b))
}

@Test func outcomesAreRecognized() {
    #expect(CompanionPhase.allCases.filter(\.isOutcome) == [.completed, .interrupted, .cancelled, .failed])
    #expect(CompanionPhase.allCases.count == 12)          // the brief's eleven plus `preparing`
    #expect(CompanionIntent.allCases.count == 11)
}
