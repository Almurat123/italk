// swift-tools-version: 6.2
import PackageDescription

// On-device neural bilingual TTS: MOSS-TTS-Nano (Core ML, vendored runtime, voice references). It is the only speech engine; the retired
// Kokoro engine and its FluidAudio dependency are gone, so nothing in the app can quietly switch to another voice.
let package = Package(
    name: "NeuralSpeech",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "NeuralSpeech", targets: ["NeuralSpeech"])],
    targets: [
        .target(name: "NeuralSpeech", exclude: ["Moss/NOTICE.md"]),
        .testTarget(name: "NeuralSpeechTests", dependencies: ["NeuralSpeech"]),
    ]
)
