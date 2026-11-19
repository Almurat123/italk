import Foundation

/// Versioned list of downloadable models. The bundled `model-manifest.json` is the source of truth: every file is pinned
/// by size and SHA-256; sources are interchangeable URL rules. The same JSON can later be published by the iTalk CDN.
/// `residentBytes` is peak MLX memory measured on a Mac; `maxAutonomy` starts conservative (see `autonomySource`).
public struct ModelManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var manifestVersion: String
    public var generatedAt: Date
    public var artifacts: [ModelArtifact]
}

public enum ModelCatalog {
    public static let manifest: ModelManifest = {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let m = try? AgentCoding.decoder().decode(ModelManifest.self, from: data) else {
            preconditionFailure("bundled model-manifest.json missing or invalid")
        }
        return m
    }()
    /// Language models (the chat model picker).
    public static var all: [ModelArtifact] { manifest.artifacts.filter { ($0.role ?? .languageModel) == .languageModel } }
    /// On-device neural voice engine (MOSS-TTS-Nano; the one speech engine).
    public static var speech: [ModelArtifact] { manifest.artifacts.filter { $0.role == .speechSynthesis } }
    public static var mossTTS: ModelArtifact? { speech.first { $0.id == "moss-tts-nano-100m-coreml" } }
    public static var qwen35_0_8b_4bit: ModelArtifact { all.first { $0.id == "qwen3.5-0.8b-4bit" }! }
    public static var qwen35_2b_4bit: ModelArtifact { all.first { $0.id == "qwen3.5-2b-4bit" }! }
}
