// Adapted from soniqo/speech-swift (Apache-2.0), Sources/MossTTSNano — see Moss/NOTICE.md.
import AVFoundation
import CoreML
import Foundation

/// Where one synthesis spent its time (seconds), for the speed investigation. Always collected: the clock reads cost nanoseconds.
public struct MossNanoProfile: Sendable, Equatable {
    public var tokenize = 0.0, prefill = 0.0, control = 0.0, localPredict = 0.0, sampling = 0.0, codec = 0.0, globalStep = 0.0
    public var frames = 0
    public var total: Double { tokenize + prefill + control + localPredict + sampling + codec + globalStep }
    public init() {}
}

@inline(__always) private func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Native stateful Core ML synthesis. Calls on one model are serialized; every request owns fresh state.
public actor MossNanoModel {
    nonisolated public let sampleRate = 48000
    public let configuration: MossNanoConfiguration
    private let directory: URL
    private let computeUnits: MLComputeUnits
    private let tokenizer: MossNanoTokenizer
    private let globalDecoder: MLModel
    private let localDecoder: MLModel
    private let codecDecoder: MLModel
    private var codecEncoder: MLModel?

    /// `global`, `local` and `codec` override the compute units of one graph (the speed investigation tries them separately).
    public init(modelDirectory: URL, computeUnits: MLComputeUnits = .cpuOnly, global: MLComputeUnits? = nil, local: MLComputeUnits? = nil, codec: MLComputeUnits? = nil) throws {
        directory = modelDirectory; self.computeUnits = computeUnits
        configuration = try JSONDecoder().decode(MossNanoConfiguration.self,
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        try configuration.validate()
        tokenizer = try MossNanoTokenizer(data: Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer_swift.json")))
        func load(_ name: String, _ units: MLComputeUnits?) throws -> MLModel {
            try Self.loadModel(modelDirectory.appendingPathComponent("\(name).mlmodelc"), units ?? computeUnits)
        }
        globalDecoder = try load("GlobalDecoder", global)
        localDecoder = try load("LocalDecoder", local)
        codecDecoder = try load("CodecDecoder", codec)
    }

    static func loadModel(_ url: URL, _ computeUnits: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Load mono/stereo audio, resample both channels together, and encode once for reuse.
    public func encodeReference(url: URL) throws -> MossNanoReference {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)), format.sampleRate.isFinite, format.sampleRate > 0,
              file.length > 0 else { throw MossNanoError.invalidInput("reference file must contain mono/stereo audio") }
        guard Double(file.length) / format.sampleRate < Double(configuration.contextLength - 1) * 0.08 else {
            throw MossNanoError.contextExceeded
        }
        return try encodeReference(channels: try Self.loadStereo(url: url, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    public func encodeReference(channels: [[Float]], sampleRate inputRate: Int) throws -> MossNanoReference {
        guard (1...2).contains(channels.count), inputRate > 0, inputRate <= 768000,
              let count = channels.first?.count, count > 0,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw MossNanoError.invalidInput("reference must contain finite, equally sized mono/stereo channels and a positive sample rate")
        }
        // Bound work before resampling or loading the encoder.
        guard Double(count) / Double(inputRate) < Double(configuration.contextLength - 1) * 0.08 else {
            throw MossNanoError.contextExceeded
        }
        var stereo = channels.count == 1 ? [channels[0], channels[0]] : channels
        if inputRate != sampleRate { stereo = try Self.resample(stereo, from: inputRate, to: sampleRate) }
        let frames = (stereo[0].count + 3839) / 3840
        guard frames > 0, frames + 1 < configuration.contextLength else { throw MossNanoError.contextExceeded }
        if codecEncoder == nil {
            codecEncoder = try Self.loadModel(directory.appendingPathComponent("CodecEncoder.mlmodelc"), computeUnits)
        }
        guard let encoder = codecEncoder else { throw MossNanoError.invalidConfiguration("missing codec encoder") }
        let state = encoder.makeState()
        var codes: [[Int32]] = []
        for frame in 0..<frames {
            try Task.checkCancellation()
            let start = frame * 3840, end = min(start + 3840, stereo[0].count)
            var values: [Float] = []
            for channel in stereo {
                values += channel[start..<end]
                values += [Float](repeating: 0, count: 3840 - (end - start))
            }
            let output = try predict(encoder, state, ["audio": floats(values, [1, 2, 3840]), "frame": ints([Int32(frame)], [1])])
            let array = try outputArray(output, "codes", [1, 1, 16], .int32)
            codes.append((0..<16).map { array[$0].int32Value })
        }
        return try MossNanoReference(codes: codes)
    }

    public func synthesize(text: String, reference: MossNanoReference? = nil,
                           options: MossNanoOptions = .init()) throws -> MossNanoResult {
        try synthesizeImpl(text: text, reference: reference, options: options)
    }

    nonisolated public func synthesizeStream(text: String, reference: MossNanoReference? = nil,
                                             options: MossNanoOptions = .init()) -> AsyncThrowingStream<MossNanoChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.synthesizeImpl(text: text, reference: reference, options: options,
                        onChunk: { continuation.yield($0) })
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Mono 48 kHz chunks as soon as each 80 ms frame is decoded; cancelling the consumer cancels synthesis.
    nonisolated public func monoStream(text: String, reference: MossNanoReference? = nil,
                                       options: MossNanoOptions = .init()) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in self.synthesizeStream(text: text, reference: reference, options: options) where !chunk.left.isEmpty {
                        continuation.yield(chunk.mono)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func synthesizeImpl(text: String, reference: MossNanoReference?, options: MossNanoOptions,
                                onChunk: (@Sendable (MossNanoChunk) -> Void)? = nil) throws -> MossNanoResult {
        let started = Date()
        var profile = MossNanoProfile()
        try options.validate()
        try Task.checkCancellation()
        guard (reference?.codes.count ?? 0) < configuration.contextLength else { throw MossNanoError.contextExceeded }
        var stage = ContinuousClock.now
        let rows = try tokenizer.prompt(text: text, reference: reference)
        profile.tokenize = seconds(since: stage)
        guard rows.count + options.maxFrames <= configuration.contextLength else { throw MossNanoError.contextExceeded }
        let globalState = globalDecoder.makeState(), localState = localDecoder.makeState(), codecState = codecDecoder.makeState()
        var hidden: MLMultiArray?
        stage = ContinuousClock.now
        for position in stride(from: 0, to: rows.count, by: configuration.prefillLimit) {
            try Task.checkCancellation()
            let batch = Array(rows[position..<min(rows.count, position + configuration.prefillLimit)])
            let output = try predict(globalDecoder, globalState,
                ["input_ids": ints(batch.flatMap { $0 }, [1, batch.count, 17]), "position": ints([Int32(position)], [1])])
            hidden = try outputArray(output, "hidden", [1, 768], .float32)
        }
        profile.prefill = seconds(since: stage)
        guard var currentHidden = hidden else { throw MossNanoError.invalidOutput("empty prompt") }
        var sampler = MossNanoSampler(state: options.seed), seen = [Set<Int>](repeating: [], count: 16)
        var codes: [[Int32]] = [], left: [Float] = [], right: [Float] = []
        var firstToken = 0.0, firstAudio = 0.0, ended = false
        func local(_ step: Int, _ previous: Int32) throws -> any MLFeatureProvider {
            try predict(localDecoder, localState, ["global_hidden": currentHidden, "previous_token": ints([previous], [1]), "step": ints([Int32(step)], [1])])
        }
        for frame in 0..<options.maxFrames {
            try Task.checkCancellation()
            stage = ContinuousClock.now
            let control = try outputArray(local(0, 0), "text_logits", [1, 2], .float32)
            profile.control += seconds(since: stage)
            stage = ContinuousClock.now
            let stop = try sampler.sample(readFloats(control), temperature: options.textTemperature, greedy: options.greedy) == 1
            profile.sampling += seconds(since: stage)
            if stop { ended = true; break }
            var frameCodes: [Int32] = [], previous: Int32 = 9
            for step in 1...16 {
                try Task.checkCancellation()
                stage = ContinuousClock.now
                let logits = try outputArray(local(step, previous), "audio_logits", [1, 1024], .float32)
                profile.localPredict += seconds(since: stage)
                stage = ContinuousClock.now
                let token = try sampler.sample(readFloats(logits), temperature: options.audioTemperature,
                    topK: options.topK, topP: options.topP, seen: seen[step - 1], penalty: options.repetitionPenalty, greedy: options.greedy)
                profile.sampling += seconds(since: stage)
                if frame == 0 && step == 1 { firstToken = Date().timeIntervalSince(started) }
                seen[step - 1].insert(token); previous = Int32(token); frameCodes.append(previous)
            }
            stage = ContinuousClock.now
            let output = try predict(codecDecoder, codecState,
                ["codes": ints(frameCodes, [1, 1, 16]), "frame": ints([Int32(frame)], [1])])
            let waveform = try outputArray(output, "audio", [1, 2, 3840], .float32)
            let samples = readFloats(waveform)
            guard samples.allSatisfy(\.isFinite) else { throw MossNanoError.invalidOutput("non-finite waveform") }
            let chunk = MossNanoChunk(left: Array(samples[..<3840]), right: Array(samples[3840...]),
                frameIndex: frame * 3840, isFinal: false, elapsedTime: Date().timeIntervalSince(started))
            profile.codec += seconds(since: stage)
            if frame == 0 { firstAudio = chunk.elapsedTime }
            left += chunk.left; right += chunk.right; codes.append(frameCodes); onChunk?(chunk)
            profile.frames += 1
            if frame + 1 < options.maxFrames {
                stage = ContinuousClock.now
                let output = try predict(globalDecoder, globalState,
                    ["input_ids": ints([9] + frameCodes, [1, 1, 17]), "position": ints([Int32(rows.count + frame)], [1])])
                currentHidden = try outputArray(output, "hidden", [1, 768], .float32)
                profile.globalStep += seconds(since: stage)
            }
        }
        guard ended else { throw MossNanoError.generationLimit }
        guard !left.isEmpty else { throw MossNanoError.invalidOutput("end-of-speech before audio") }
        let elapsed = Date().timeIntervalSince(started)
        onChunk?(MossNanoChunk(left: [], right: [], frameIndex: left.count, isFinal: true, elapsedTime: elapsed))
        var result = MossNanoResult(left: left, right: right, codes: codes, generationSeconds: elapsed,
            firstTokenSeconds: firstToken, firstAudioSeconds: firstAudio)
        result.profile = profile
        return result
    }

    private func ints(_ values: [Int32], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        array.dataPointer.assumingMemoryBound(to: Int32.self).update(from: values, count: values.count)
        return array
    }
    private func floats(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        array.dataPointer.assumingMemoryBound(to: Float.self).update(from: values, count: values.count)
        return array
    }
    private func predict(_ model: MLModel, _ state: MLState, _ inputs: [String: MLMultiArray]) throws -> any MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs), using: state)
    }
    private func outputArray(_ output: any MLFeatureProvider, _ name: String, _ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        guard let array = output.featureValue(for: name)?.multiArrayValue,
              array.shape.map(\.intValue) == shape, array.dataType == type else {
            throw MossNanoError.invalidOutput("\(name) must have shape \(shape) and type \(type)")
        }
        return array
    }
    private func readFloats(_ array: MLMultiArray) -> [Float] {
        // Contiguous float32 outputs (the normal case) are copied in one go: boxing every element through NSNumber costs more
        // than the decoder itself for the 7,680-sample waveform and the 16 x 1,024 logits of each frame.
        if array.dataType == .float32 {
            var expected = 1, contiguous = true
            for (dimension, stride) in zip(array.shape.reversed(), array.strides.reversed()) {
                if dimension.intValue != 1 && stride.intValue != expected { contiguous = false; break }
                expected *= dimension.intValue
            }
            if contiguous { return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) } }
        }
        // Respect Core ML output strides rather than assuming contiguous storage.
        return (0..<array.count).map { array[$0].floatValue }
    }
    /// Reads any audio file as stereo at `sampleRate` (mono is duplicated).
    static func loadStereo(url: URL, sampleRate: Int) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MossNanoError.invalidInput("cannot allocate reference buffer")
        }
        try file.read(into: inBuffer)
        guard let channels = inBuffer.floatChannelData else { throw MossNanoError.invalidInput("reference is not float audio") }
        let count = Int(inBuffer.frameLength)
        let raw = (0..<Int(source.channelCount)).map { Array(UnsafeBufferPointer(start: channels[$0], count: count)) }
        let stereo = raw.count == 1 ? [raw[0], raw[0]] : [raw[0], raw[1]]
        return source.sampleRate == Double(sampleRate) ? stereo : try resample(stereo, from: Int(source.sampleRate), to: sampleRate)
    }

    /// Both channels are converted together with the system sample-rate converter.
    static func resample(_ channels: [[Float]], from: Int, to: Int) throws -> [[Float]] {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(from), channels: AVAudioChannelCount(channels.count), interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(to), channels: AVAudioChannelCount(channels.count), interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(channels[0].count)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(channels[0].count) * Double(to) / Double(from)) + 1024) else {
            throw MossNanoError.invalidInput("cannot resample reference audio")
        }
        input.frameLength = AVAudioFrameCount(channels[0].count)
        for (i, channel) in channels.enumerated() { channel.withUnsafeBufferPointer { input.floatChannelData![i].update(from: $0.baseAddress!, count: channel.count) } }
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return (0..<channels.count).map { Array(UnsafeBufferPointer(start: output.floatChannelData![$0], count: Int(output.frameLength))) }
    }
}
