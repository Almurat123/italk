#if DEBUG || ITALK_PROBES
import AVFoundation
import UIKit
import Speech
import Foundation
import OSLog
import AssistantCore

/// Device self-test for "does the beginning of speech survive?". It starts capture exactly like a press does, plays a known
/// sentence from the loudspeaker the moment the microphone is running (before the recognizer is ready), and compares what was
/// recognized with what was played. Echo cancellation is off for the probe so the microphone can hear the speaker.
///
/// Launch with `-captureProbe`; the result is written to Documents/capture-probe.json.
@MainActor enum CaptureProbe {
    struct Trial: Codable {
        var name: String
        var expected: String
        var heard: String
        var characterErrorRate: Double
        /// Leading characters of the sentence that are missing from the start of the transcript.
        var missingLeading: Int
        var warmRecognizer: Bool
        var requestToMicRunningMs: Double?
        var requestToFirstBufferMs: Double?
        var firstBufferFrames: Int?
        var micToRecognizerReadyMs: Double?
        var requestToFirstTextMs: Double?
        var backlogHandled: Bool
    }
    struct Report: Codable { var device: String; var os: String; var date: Date; var trials: [Trial] }

    private static let log = Logger(subsystem: "com.italk.assistant", category: "capture-probe")

    static let sentences: [(name: String, text: String, language: String)] = [
        ("zh", "今天下午三点帮我提醒一下开会，地点在二楼会议室。", "zh-CN"),
        ("zh-short", "你好，我想问一下明天的天气。", "zh-CN"),
    ]

    static func run() async {
        log.info("capture probe start")
        // The phone is unattended: keep the screen awake, otherwise iOS suspends the app mid-measurement (seen as 60–300 s stalls).
        // No silent-audio keep-alive here: it would own the audio session this probe configures itself (record + play).
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        var trials: [Trial] = []
        let input = SpeechInput()
        for s in sentences {
            guard let url = await render(s.text, language: s.language) else { log.error("no system voice for \(s.language, privacy: .public)"); continue }
            // Cold: nothing prepared (first use after launch is the worst case).
            trials.append(await trial(name: s.name + "-cold", text: s.text, audio: url, input: input, warm: false))
            try? await Task.sleep(for: .seconds(1.5))
            // Warm: the recognizer was prepared ahead of the press.
            input.warmDictationAssets()
            try? await Task.sleep(for: .seconds(4))
            trials.append(await trial(name: s.name + "-warm", text: s.text, audio: url, input: input, warm: true))
            try? await Task.sleep(for: .seconds(1.5))
        }
        let report = Report(device: ProcessInfo.processInfo.hostName, os: ProcessInfo.processInfo.operatingSystemVersionString, date: .now, trials: trials)
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("capture-probe.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(report) { try? data.write(to: out); log.info("capture probe done: \(out.path, privacy: .public)") }
        for t in trials {
            log.info("probe \(t.name, privacy: .public) cer=\(t.characterErrorRate, privacy: .public) missingLeading=\(t.missingLeading, privacy: .public) mic=\(t.requestToMicRunningMs ?? -1, privacy: .public)ms ready=\(t.micToRecognizerReadyMs ?? -1, privacy: .public)ms heard=\(t.heard, privacy: .public)")
        }
    }

    @MainActor private final class Box {
        var heard = "", stages: [String: Double] = [:], firstFrames: Int?, ok = true
        var player: AVAudioPlayer?
    }

    private static func trial(name: String, text: String, audio: URL, input: SpeechInput, warm: Bool) async -> Trial {
        let box = Box()
        let t0 = ProcessInfo.processInfo.systemUptime
        do {
            try await input.start(duplex: true, preferEchoCancellation: false, onText: { box.heard = $0 }, onActivity: {}, onError: { _ in box.ok = false }, onLevel: { _ in },
                onStage: { stage in
                    let now = ProcessInfo.processInfo.systemUptime
                    switch stage {
                    case .micRunning:
                        box.stages["mic"] = now
                        // The sentence starts the instant the microphone runs: the recognizer is certainly not ready yet.
                        box.player = try? AVAudioPlayer(contentsOf: audio)
                        box.player?.volume = 1
                        box.player?.play()
                    case .firstBuffer(let frames): box.stages["buffer"] = now; box.firstFrames = frames
                    case .recognizerReady: box.stages["ready"] = now
                    case .firstText: if box.stages["text"] == nil { box.stages["text"] = now }
                    default: break
                    }
                })
            let duration = (try? AVAudioPlayer(contentsOf: audio).duration) ?? 4
            try? await Task.sleep(for: .seconds(duration + 1.2))
            try await input.finish()
        } catch { box.ok = false; await input.cancel() }
        box.player?.stop()
        func ms(_ key: String) -> Double? { box.stages[key].map { ($0 - t0) * 1000 } }
        let expected = normalize(text), got = normalize(box.heard)
        let cer = Double(distance(Array(expected), Array(got))) / Double(max(expected.count, 1))
        var missing = 0
        let eChars = Array(expected), gChars = Array(got)
        if let firstHeard = gChars.first, let idx = eChars.firstIndex(of: firstHeard) { missing = idx } else { missing = eChars.count }
        return Trial(name: name, expected: text, heard: box.heard, characterErrorRate: (cer * 1000).rounded() / 1000, missingLeading: missing, warmRecognizer: warm,
                     requestToMicRunningMs: ms("mic"), requestToFirstBufferMs: ms("buffer"), firstBufferFrames: box.firstFrames,
                     micToRecognizerReadyMs: box.stages["ready"].flatMap { r in box.stages["mic"].map { (r - $0) * 1000 } },
                     requestToFirstTextMs: ms("text"), backlogHandled: box.stages["ready"] != nil)
    }

    private static func normalize(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var dp = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var prev = dp[0]; dp[0] = i
            for j in 1...max(b.count, 1) where j <= b.count {
                let cur = dp[j]
                dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1)); prev = cur
            }
        }
        return dp[b.count]
    }

    /// Renders text to a caf file with the system voice (no playback), so the same signal is used for every trial.
    private static func render(_ text: String, language: String) async -> URL? {
        guard let voice = AVSpeechSynthesisVoice(language: language) else { return nil }
        let renderer = Renderer()
        return await renderer.render(text, voice: voice)
    }

    private final class Renderer: @unchecked Sendable {
        private let synth = AVSpeechSynthesizer()
        private var file: AVAudioFile?
        private var finished = false
        func render(_ text: String, voice: AVSpeechSynthesisVoice) async -> URL? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).caf")
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                synth.write(utterance) { [self] buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        if !finished { finished = true; continuation.resume(returning: file == nil ? nil : url) }
                        return
                    }
                    if file == nil { file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                    try? file?.write(from: pcm)
                }
            }
        }
    }
}
#endif
