import Foundation
import CoreML
import AVFoundation
import NeuralSpeech

// usage:
//   neural-bench moss <modelDir> [--units cpu|gpu|all|ne] [--voice <voice.json>] [--out <dir>] [--repeat N]
//   neural-bench encode <modelDir> <reference.wav> <out.json> [name]
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

let sentences: [(String, String)] = [
    ("zh-short", "好的，我来帮你看一下。"),
    ("zh-chat", "明天杭州天气不错，最高二十五度，适合出门走走，不过早晚有点凉，记得带件外套。"),
    ("zh-comfort", "别担心，这种事情很常见，我们一步一步来解决，一定没问题的。"),
    ("zh-excited", "太棒了！你的方案通过了，恭喜你！我们今晚一起庆祝一下吧。"),
    ("en-chat", "Sure, I can set an alarm for ten tomorrow morning. Do you want it to repeat on weekdays?"),
    ("mix", "这个 meeting 改到下午三点了，记得提前 prepare 一下 slides，然后把 deadline 发给我。"),
]

func units(_ name: String?) -> MLComputeUnits {
    switch name { case "gpu": .cpuAndGPU; case "all": .all; case "ne": .cpuAndNeuralEngine; default: .cpuOnly }
}

func writeWav(_ samples: [Float], rate: Double, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
    try file.write(from: buffer)
}

func run() async throws {
    guard let command = args.first else { print("usage: neural-bench moss|encode …"); return }
    switch command {
    case "moss":
        let dir = URL(fileURLWithPath: args[1])
        let speaker = MossNanoSpeaker(modelDirectory: dir, computeUnits: units(option("--units")))
        var voiceId = "default"
        if let path = option("--voice") {
            let voice = try JSONDecoder().decode(MossVoice.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            await speaker.register(voice); voiceId = voice.id
        }
        let loadStart = Date()
        try await speaker.load(voice: voiceId)
        print(String(format: "load %.2fs (units=%@)", Date().timeIntervalSince(loadStart), option("--units") ?? "cpu"))
        let out = option("--out").map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let repeats = Int(option("--repeat") ?? "1") ?? 1
        for r in 0..<repeats {
            for (id, text) in sentences {
                let start = Date()
                var first: Double?, samples: [Float] = []
                for try await chunk in speaker.stream(text, voice: voiceId, speed: 1, style: option("--style")) {
                    if first == nil { first = Date().timeIntervalSince(start) * 1000 }
                    samples += chunk
                }
                let wall = Date().timeIntervalSince(start), audio = Double(samples.count) / 48_000
                print(String(format: "%@%@  first audio %4.0f ms  audio %5.2fs  gen %5.2fs  RTF %.2f", r == 0 ? "" : "(warm) ", id, first ?? -1, audio, wall, wall / max(audio, 0.001)))
                if let out, r == repeats - 1 { try writeWav(samples, rate: 48_000, to: out.appendingPathComponent("\(id).wav")) }
            }
        }
    case "profile":
        // Where the time goes: neural-bench profile <modelDir> [--global cpu|gpu|ne|all] [--local …] [--codec …] [--repeat N]
        let dir = URL(fileURLWithPath: args[1])
        let loadStart = Date()
        let model = try MossNanoModel(modelDirectory: dir, computeUnits: units(option("--units")),
                                      global: option("--global").map(units), local: option("--local").map(units), codec: option("--codec").map(units))
        print(String(format: "load %.2fs  global=%@ local=%@ codec=%@", Date().timeIntervalSince(loadStart),
                     option("--global") ?? option("--units") ?? "cpu", option("--local") ?? option("--units") ?? "cpu", option("--codec") ?? option("--units") ?? "cpu"))
        let voice = MossVoiceLibrary.voices[0]
        let reference = voice.reference(for: nil)
        _ = try await model.synthesize(text: "好的。", reference: reference)       // not counted: first prediction pays one-time costs
        var total = MossNanoProfile(), audioTotal = 0.0, wallTotal = 0.0
        for r in 0..<(Int(option("--repeat") ?? "1") ?? 1) {
            for (id, text) in sentences where ["zh-chat", "en-chat", "mix"].contains(id) {
                let start = Date()
                let result = try await model.synthesize(text: text, reference: reference)
                let wall = Date().timeIntervalSince(start), p = result.profile
                print(String(format: "%@%@  audio %5.2fs  wall %5.2fs RTF %.2f | frames %3d  tokenize %4.0f  prefill %4.0f ms | per frame (ms): control %.1f local×16 %.1f sampling %.1f codec %.1f global %.1f = %.1f",
                             r == 0 ? "" : "(warm) ", id, result.duration, wall, wall / result.duration, p.frames, p.tokenize * 1000, p.prefill * 1000,
                             p.control / Double(p.frames) * 1000, p.localPredict / Double(p.frames) * 1000, p.sampling / Double(p.frames) * 1000,
                             p.codec / Double(p.frames) * 1000, p.globalStep / Double(p.frames) * 1000, p.total / Double(p.frames) * 1000))
                total.tokenize += p.tokenize; total.prefill += p.prefill; total.control += p.control; total.localPredict += p.localPredict
                total.sampling += p.sampling; total.codec += p.codec; total.globalStep += p.globalStep; total.frames += p.frames
                audioTotal += result.duration; wallTotal += wall
            }
        }
        let f = Double(max(total.frames, 1))
        print(String(format: "TOTAL  frames %d  audio %.1fs  wall %.1fs  RTF %.2f  (frame budget 80 ms)", total.frames, audioTotal, wallTotal, wallTotal / audioTotal))
        print(String(format: "  per frame ms: control %.2f  local %.2f  sampling %.2f  codec %.2f  global %.2f  | prefill+tokenize per request %.0f ms",
                     total.control / f * 1000, total.localPredict / f * 1000, total.sampling / f * 1000, total.codec / f * 1000, total.globalStep / f * 1000,
                     (total.prefill + total.tokenize) / 3 * 1000))
    case "library":
        // Listening pack: every shipping voice (MossVoiceLibrary) reading the test sentences, written as <out>/<voice>-<sentence>.wav
        let speaker = MossNanoSpeaker(modelDirectory: URL(fileURLWithPath: args[1]), computeUnits: units(option("--units") ?? "gpu"))
        for v in MossVoiceLibrary.voices { await speaker.register(v) }
        guard let out = option("--out").map({ URL(fileURLWithPath: $0) }) else { print("--out <dir> is required"); return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for v in MossVoiceLibrary.voices {
            try await speaker.load(voice: v.id)
            for (id, text) in sentences where ["zh-chat", "zh-comfort", "en-chat", "mix"].contains(id) {
                let start = Date(); var samples: [Float] = []
                for try await chunk in speaker.stream(text, voice: v.id, speed: 1, style: id == "zh-comfort" ? "comfort" : nil) { samples += chunk }
                let audio = Double(samples.count) / 48_000
                print(String(format: "%@ %@  audio %5.2fs  RTF %.2f", v.id, id, audio, Date().timeIntervalSince(start) / max(audio, 0.001)))
                try writeWav(samples, rate: 48_000, to: out.appendingPathComponent("\(v.id)-\(id).wav"))
            }
        }
    case "encode":
        let speaker = MossNanoSpeaker(modelDirectory: URL(fileURLWithPath: args[1]))
        let codes = try await speaker.encodeReference(url: URL(fileURLWithPath: args[2]))
        let name = args.count > 4 ? args[4] : URL(fileURLWithPath: args[3]).deletingPathExtension().lastPathComponent
        let voice = MossVoice(id: name, name: name, references: ["neutral": codes])
        try JSONEncoder().encode(voice).write(to: URL(fileURLWithPath: args[3]))
        print("encoded \(codes.count) frames (\(Double(codes.count) * 0.08) s) → \(args[3])")
    default: print("unknown command")
    }
}

do { try await run() } catch { print("error: \(error)"); exit(1) }
