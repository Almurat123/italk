// Transcribes WAV files with Apple's on-device SpeechTranscriber (the same recognizer family iTalk uses on the phone).
// Used as an independent intelligibility check for synthesized speech: the round-trip error rate flags skipped words,
// mispronounced numbers and mixed-language failures that prosody statistics cannot see.
//
//   swiftc -O asr-check.swift -o asr-check && ./asr-check zh-CN a.wav b.wav     → one line per file: path<TAB>transcript
import Foundation
import Speech
import AVFoundation

@main struct ASRCheck {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: asr-check <locale> <wav>...\n".utf8)); exit(2) }
        let locale = Locale(identifier: args.removeFirst())
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            FileHandle.standardError.write(Data("locale not supported\n".utf8)); exit(3)
        }
        for path in args {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            do {
                if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let collector = Task { () -> String in
                    var text = ""
                    for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
                    return text
                }
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let text = try await collector.value
                print("\(path)\t\(text.replacingOccurrences(of: "\n", with: " "))")
            } catch {
                print("\(path)\t")
                FileHandle.standardError.write(Data("error \(path): \(error)\n".utf8))
            }
        }
    }
}
