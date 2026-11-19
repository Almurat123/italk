import Foundation
import CoreML

/// What the app's speech output needs from any on-device voice engine: mono float PCM, delivered as soon as it exists.
public protocol NeuralSynthesizer: Sendable {
    var engineId: String { get }
    var sampleRate: Double { get }
    /// Loads weights (and compiles Core ML graphs on first use). Safe to call repeatedly.
    func load(voice: String) async throws
    func unload() async
    /// Mono PCM chunks in playback order. Cancelling the consuming task stops synthesis. `style` selects an emotion variant
    /// when the engine has one ("neutral", "cheerful", "calm"); engines without styles ignore it.
    func stream(_ text: String, voice: String, speed: Float, style: String?) -> AsyncThrowingStream<[Float], Error>
    /// The engine applies `speed` itself (otherwise the player time-stretches).
    var supportsNativeSpeed: Bool { get }
}

/// A voice for MOSS-TTS-Nano is a short reference recording, stored as the codec codes the model conditions on. Optional
/// emotion variants are further references of the same speaker; `neutral` is the default and the fallback.
public struct MossVoice: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var references: [String: [[Int32]]]
    public init(id: String, name: String, references: [String: [[Int32]]]) { self.id = id; self.name = name; self.references = references }

    /// Built-in voices ship as base64 of little-endian Int16 codes (16 per frame): small source, no huge array literals to compile.
    public init(id: String, name: String, packed: [String: String]) {
        var refs: [String: [[Int32]]] = [:]
        for (style, text) in packed {
            guard let data = Data(base64Encoded: text) else { continue }
            let values = stride(from: 0, to: data.count - 1, by: 2).map { Int32(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) }
            refs[style] = stride(from: 0, to: values.count - 15, by: 16).map { Array(values[$0..<($0 + 16)]) }
        }
        self.init(id: id, name: name, references: refs)
    }

    public func reference(for style: String?) -> MossNanoReference? {
        guard let codes = references[style ?? "neutral"] ?? references["neutral"] ?? references.values.first else { return nil }
        return try? MossNanoReference(codes: codes)
    }
}

/// MOSS-TTS-Nano on device: streams 80 ms frames (48 kHz) as they are decoded. Weights are ~300 MB (Global + Local + Codec decoders);
/// voices are tiny reference-code files, so adding a voice never adds weights.
public actor MossNanoSpeaker: NeuralSynthesizer {
    public nonisolated var engineId: String { "moss-tts-nano-100m" }
    public nonisolated var sampleRate: Double { 48_000 }
    private let directory: URL
    private let computeUnits: MLComputeUnits
    private var model: MossNanoModel?
    private var voices: [String: MossVoice] = [:]
    public private(set) var loadSeconds: Double?

    public init(modelDirectory: URL, computeUnits: MLComputeUnits = .cpuOnly) { directory = modelDirectory; self.computeUnits = computeUnits }

    public func register(_ voice: MossVoice) { voices[voice.id] = voice }
    public func unregister(_ id: String) { voices[id] = nil }

    public func load(voice: String) async throws {
        if model != nil { return }
        let start = ContinuousClock.now
        model = try MossNanoModel(modelDirectory: directory, computeUnits: computeUnits)
        let d = ContinuousClock.now - start
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public func unload() { model = nil }

    public nonisolated var supportsNativeSpeed: Bool { false }

    /// `style` selects an emotion variant of the voice's reference ("neutral", "cheerful", "calm", …) when the voice has one.
    public nonisolated func stream(_ text: String, voice: String, speed: Float, style: String?) -> AsyncThrowingStream<[Float], Error> {
        stream(text, voice: voice, style: style, seed: 0)
    }

    nonisolated func stream(_ text: String, voice: String, style: String?, seed: UInt64) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.load(voice: voice)
                    guard let model = await self.model else { throw CancellationError() }
                    let reference = await self.voices[voice]?.reference(for: style)
                    var options = MossNanoOptions(); options.seed = seed
                    for try await chunk in model.monoStream(text: text, reference: reference, options: options) { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// For tooling that builds voice packs on a Mac: encodes a recording into reference codes (needs CodecEncoder.mlmodelc).
    public func encodeReference(url: URL) async throws -> [[Int32]] {
        try await load(voice: "")
        guard let model else { throw CancellationError() }
        return try await model.encodeReference(url: url).codes
    }
}
