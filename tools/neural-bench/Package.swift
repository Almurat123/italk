// swift-tools-version: 6.2
import PackageDescription

// Mac tooling for the on-device voice engines: speed benchmark and voice-pack (reference code) builder.
let package = Package(
    name: "neural-bench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/NeuralSpeech")],
    targets: [.executableTarget(name: "neural-bench", dependencies: [.product(name: "NeuralSpeech", package: "NeuralSpeech")])]
)
