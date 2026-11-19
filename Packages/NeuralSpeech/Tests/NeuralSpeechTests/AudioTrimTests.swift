import Foundation
import Testing
@testable import NeuralSpeech

@Suite struct AudioTrimTests {
    private func tone(_ seconds: Double, rate: Double = 16_000, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 0.2) }
    }
    private func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    @Test func leadingSilenceIsMeasuredToTheOnset() {
        let x = silence(0.2) + tone(0.5)
        let n = AudioTrim.leadingSilence(x, rate: 16_000)
        #expect(n != nil && abs(n! - 3200) <= 160)
    }

    @Test func allSilentBufferIsUndecided() {
        #expect(AudioTrim.leadingSilence(silence(0.5), rate: 16_000) == nil)
    }

    @Test func trailingSilenceIsMeasured() {
        let x = tone(0.5) + silence(0.15)
        let n = AudioTrim.trailingSilence(x, rate: 16_000)
        #expect(abs(n - 2400) <= 160)
        #expect(AudioTrim.trailingSilence(tone(0.5), rate: 16_000) == 0)
    }

    @Test func pausesFollowPunctuation() {
        #expect(AudioTrim.pause(after: "今天天气不错。") > AudioTrim.pause(after: "今天天气不错，"))
        #expect(AudioTrim.pause(after: "好的，") > AudioTrim.pause(after: "好的"))
        #expect(AudioTrim.pause(after: "他说：“你好。”") == AudioTrim.pause(after: "你好。"))
    }

    @Test func fadeStartsAndEndsAtZero() {
        var x = tone(0.1)
        AudioTrim.fade(&x, rate: 16_000, inMs: 5, outMs: 5)
        #expect(x.first == 0 && abs(x.last!) < 0.01)
    }
}
