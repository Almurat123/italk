import Foundation
import Testing
@testable import NeuralSpeech

@Suite struct MossVoiceTests {
    @Test func builtInVoicesDecodeToValidCodecFrames() throws {
        let voices = MossVoiceLibrary.voices
        #expect(voices.count >= 4)
        for voice in voices {
            #expect(MossVoiceLibrary.info[voice.id] != nil)
            #expect(voice.references.keys.contains("neutral"))
            for (style, codes) in voice.references {
                #expect(codes.count >= 20 && codes.count <= 200, "\(voice.id)/\(style) has \(codes.count) frames")
                #expect(codes.allSatisfy { $0.count == 16 && $0.allSatisfy { (0..<1024).contains($0) } })
                #expect(voice.reference(for: style) != nil)
            }
        }
    }

    @Test func unknownStyleFallsBackToNeutral() throws {
        let voice = try #require(MossVoiceLibrary.voices.first)
        let neutral = try #require(voice.reference(for: nil))
        let fallback = try #require(voice.reference(for: "no-such-style"))
        #expect(neutral.codes == fallback.codes)
    }

    @Test func packedRoundTrip() throws {
        let codes: [[Int32]] = [(0..<16).map(Int32.init), (0..<16).map { Int32(1023 - $0) }]
        var bytes = Data()
        for v in codes.flatMap({ $0 }) { let u = UInt16(bitPattern: Int16(v)); bytes.append(UInt8(u & 0xff)); bytes.append(UInt8(u >> 8)) }
        let voice = MossVoice(id: "t", name: "t", packed: ["neutral": bytes.base64EncodedString()])
        #expect(voice.references["neutral"] == codes)
    }

    @Test func tokenizerRejectsEmptyPrompt() throws {
        #expect(throws: (any Error).self) {
            let archive = #"{"format":"x","pieces":[],"precompiled_charsmap":""}"#
            _ = try MossNanoTokenizer(data: Data(archive.utf8))
        }
    }
}

/// Real synthesis with the locally installed MOSS-TTS-Nano bundle (ITALK_MOSS_DIR). Mac numbers only; asserts the stream is
/// incremental (first audio long before the end) and that the default library voice produces non-silent audio.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ITALK_MOSS_DIR"] != nil))
func mossStreamsIncrementally() async throws {
    let speaker = MossNanoSpeaker(modelDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ITALK_MOSS_DIR"]!))
    for voice in MossVoiceLibrary.voices { await speaker.register(voice) }
    try await speaker.load(voice: "moss-yunshu")
    let start = ContinuousClock.now
    var chunks = 0, samples = 0, firstAt: Duration?, peak: Float = 0
    for try await pcm in speaker.stream("你好，今天过得怎么样？", voice: "moss-yunshu", speed: 1, style: "neutral") {
        if firstAt == nil { firstAt = ContinuousClock.now - start }
        chunks += 1; samples += pcm.count; peak = max(peak, pcm.map(abs).max() ?? 0)
    }
    let total = ContinuousClock.now - start
    #expect(chunks > 5)
    #expect(peak > 0.05)
    #expect(Double(samples) / 48_000 > 1.0)
    #expect(try #require(firstAt) < total / 2)
}
