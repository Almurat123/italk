#if DEBUG || ITALK_PROBES
import Foundation
import AVFoundation
import UIKit
import os
import NeuralSpeech
import AssistantCore


/// Keeps an unattended phone running measurements: while an audio session is playing (silence), iOS lets the app keep executing
/// after the screen locks. Without it a probe stalls whenever the device sleeps and the numbers are meaningless.
@MainActor final class ProbeKeepAlive {
    private let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            silence.frameLength = 44_100
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
        } catch { Logger(subsystem: "com.italk.assistant", category: "probe").error("keep-alive failed: \(error.localizedDescription, privacy: .public)") }
    }
    func stop() { player.stop(); engine.stop(); UIApplication.shared.isIdleTimerDisabled = false }
}

/// On-device speed, memory and playback check for the voice engines. Launch with `-ttsProbe`; the result is written to
/// Documents/tts-probe.json. If Documents/import/moss-tts-nano-100m-coreml exists (copied from a Mac), it is imported first
/// through the hash-checking model store.
@MainActor enum TTSProbe {
    struct Synthesis: Codable {
        var voice: String; var style: String; var text: String
        var firstAudioMs: Double; var audioSeconds: Double; var generationSeconds: Double; var rtf: Double
        var footprintMB: Int; var thermal: String
    }
    struct Playback: Codable {
        var voice: String; var firstAudioMs: Double?; var underruns: Int; var completed: Bool; var totalSeconds: Double
        var heard: String
    }
    struct Report: Codable {
        var device: String; var os: String; var date: Date
        var imported: Bool; var installed: Bool; var calibrationRTF: Double?; var loadSeconds: Double?
        var footprintBeforeMB: Int; var synthesis: [Synthesis]; var playback: [Playback]; var note: String
    }

    private static let log = Logger(subsystem: "com.italk.assistant", category: "tts-probe")
    static let texts = [
        "明天杭州天气不错，最高二十五度，适合出门走走，不过早晚有点凉，记得带件外套。",
        "Sure, I can set an alarm for ten tomorrow morning. Do you want it to repeat on weekdays?",
        "这个 meeting 改到下午三点了，记得提前 prepare 一下 slides。",
    ]

    static func run(center: NeuralVoiceCenter, output: NeuralSpeechOutput) async {
        log.info("tts probe start")
        // The phone is unattended: keep the screen awake, otherwise iOS suspends the app mid-measurement (seen as 60–300 s stalls).
        let keepAlive = ProbeKeepAlive(); keepAlive.start()
        defer { keepAlive.stop() }
        var report = Report(device: ProcessInfo.processInfo.hostName, os: ProcessInfo.processInfo.operatingSystemVersionString, date: .now,
                            imported: false, installed: false, calibrationRTF: nil, loadSeconds: nil, footprintBeforeMB: footprint(),
                            synthesis: [], playback: [], note: "")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let staged = documents.appendingPathComponent("import/moss-tts-nano-100m-coreml", isDirectory: true)
        await center.refresh()
        if !center.isInstalled, FileManager.default.fileExists(atPath: staged.path) {
            do { try await center.importEngine(from: staged); report.imported = true; try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            catch { report.note = "import failed: \(error.localizedDescription)" }
        }
        report.installed = center.isInstalled
        if let moss = center.speaker, center.isInstalled {
            center.measureSpeedIfNeeded()
            for _ in 0..<240 where center.synthesis.median == nil { try? await Task.sleep(for: .milliseconds(500)) }
            report.calibrationRTF = center.synthesis.median
            report.loadSeconds = await moss.loadSeconds
            for voice in NeuralVoiceCenter.voices {
                for (i, text) in texts.enumerated() {
                    let style = i == 0 ? "neutral" : (i == 1 ? "cheerful" : "calm")
                    let start = ContinuousClock.now
                    var first: Double?, samples = 0
                    do {
                        for try await pcm in moss.stream(text, voice: voice.id, speed: 1, style: style) {
                            if first == nil { first = ms(ContinuousClock.now - start) }
                            samples += pcm.count
                        }
                    } catch { report.note += " synth error \(voice.id): \(error.localizedDescription)"; continue }
                    let wall = ms(ContinuousClock.now - start) / 1000, audio = Double(samples) / 48_000
                    report.synthesis.append(Synthesis(voice: voice.id, style: style, text: text, firstAudioMs: first ?? -1, audioSeconds: audio,
                                                      generationSeconds: wall, rtf: wall / max(audio, 0.001), footprintMB: footprint(), thermal: thermal()))
                }
            }
            keepAlive.stop()      // the playback test configures the audio session itself
            // The real pipeline, end to end, with the first MOSS voice (ensures it is the one routed).
            UserDefaults.standard.set(NeuralVoiceCenter.voices.first?.id, forKey: NeuralVoiceCenter.voiceKey)
            for voice in NeuralVoiceCenter.voices.prefix(2) {
                UserDefaults.standard.set(voice.id, forKey: NeuralVoiceCenter.voiceKey)
                report.playback.append(await play(output, voice: voice.id))
                try? await Task.sleep(for: .seconds(1))
            }
        } else if report.note.isEmpty { report.note = "MOSS not installed and nothing staged for import" }
        let out = documents.appendingPathComponent("tts-probe.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(report) { try? data.write(to: out) }
        log.info("tts probe done installed=\(report.installed, privacy: .public) rtf=\(report.calibrationRTF ?? -1, privacy: .public)")
    }

    private static func play(_ output: NeuralSpeechOutput, voice: String) async -> Playback {
        let start = ContinuousClock.now
        var firstAudio: Double?, completed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            output.begin(onLevel: { _ in }, onFirstAudio: { firstAudio = ms(ContinuousClock.now - start) }, completed: { ok in completed = ok; continuation.resume() })
            output.enqueue(["你好，我是 iTalk。", "今天下午三点半提醒你开会，记得提前出发哦。", "If you prefer English, I can switch right away."])
            output.finishInput()
        }
        return Playback(voice: voice, firstAudioMs: firstAudio, underruns: output.lastUnderruns, completed: completed,
                        totalSeconds: ms(ContinuousClock.now - start) / 1000, heard: output.playedText)
    }

    private static func ms(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }
    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; default: "critical" }
    }
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }
}
#endif
