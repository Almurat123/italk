import Foundation
import AgentRuntime
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Tokenizers

/// Runs a downloaded MLX model on the GPU through the shared `ModelProvider` contract.
/// Weights come from `ModelStore` (hash-verified); this type never touches the network.
public final class MLXModelProvider: ModelProvider, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    private let directory: URL
    private let engine = Engine()
    private let enableThinking: Bool
    private let vision: Bool
    private let diagnostic: (@Sendable (String) -> Void)?

    /// `vision`: load through MLX's VLM factory (Qwen3.5 artifacts ship the vision tower). Text-only otherwise.
    public init(artifact: ModelArtifact, directory: URL, vision: Bool = true, enableThinking: Bool = false, diagnostic: (@Sendable (String) -> Void)? = nil) {
        self.vision = vision
        self.diagnostic = diagnostic
        self.directory = directory
        self.enableThinking = enableThinking
        descriptor = ModelDescriptor(
            id: artifact.id, kind: .localDownloaded, displayName: artifact.displayName,
            capabilities: ProviderCapabilities(
                contextWindow: artifact.contextTokens, streaming: true,
                // Qwen-style tool calls are parsed natively, but reliability is unmeasured: declare "constrained"
                // and let `maxAutonomy` (from benchmarks) decide how much the runner trusts it.
                toolCalling: .constrained, structuredOutput: false, maxAutonomy: artifact.maxAutonomy,
                worksOffline: true, sendsContentOffDevice: false, estimatedResidentBytes: artifact.residentBytes, visionInput: vision,
                // Measured (AgentBenchTests): native discovery 65% (2B) / 21% (0.8B); guided selection is the default for on-device models.
                skillSelection: .guided))
    }

    public func prepare(progress: @Sendable (PreparationState) -> Void) async throws {
        if await engine.isLoaded { progress(.ready); return }
        progress(.loading(fraction: nil))
        do { try await engine.load(directory: directory, vision: vision) }
        catch { progress(.failed("\(error)")); throw ProviderError.failed("model load failed") }
        progress(.ready)
    }

    public func unload() async { await engine.unload() }

    /// The exact prompt size of `request` for this model: its tokenizer and chat template (tool schemas and images included), without generating.
    public func promptTokenCount(_ request: GenerationRequest) async -> Int? {
        try? await engine.countPromptTokens(request: request, thinking: enableThinking || request.reasoning)
    }
    /// Generations still holding the GPU. Zero after a cancelled stream means the engine really stopped.
    public var activeGenerations: Int { get async { await engine.active } }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let thinking = enableThinking || request.reasoning, id = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard await engine.isLoaded else { throw ProviderError.notPrepared }
                    var parser = ToolCallTextParser(idPrefix: request.requestId)
                    // Thinking mode opens the reasoning block inside the prompt, so output starts inside it.
                    var think = ReasoningTextParser(startsInside: thinking)
                    let started = ContinuousClock.now
                    var firstToken: Double?
                    var sawToolCall = false
                    var info: GenerateCompletionInfo?
                    await engine.begin(); defer { Task { await engine.end() } }
                    let stream = try await engine.stream(request: request, thinking: thinking)
                    for await part in stream {
                        try Task.checkCancellation()
                        switch part {
                        case .chunk(let s):
                            if firstToken == nil { firstToken = (ContinuousClock.now - started).seconds }
                            let split = think.feed(s)
                            if !split.reasoning.isEmpty { continuation.yield(.reasoningDelta(split.reasoning)) }
                            let out = parser.feed(split.text)
                            if !out.text.isEmpty { continuation.yield(.textDelta(out.text)) }
                            for c in out.calls { sawToolCall = true; continuation.yield(.toolCall(c)) }
                        case .toolCall(let call):
                            sawToolCall = true
                            let args = Self.convert(call.function.arguments)
                            continuation.yield(.toolCall(ToolCall(id: call.id ?? "\(request.requestId)-n\(call.function.name)", name: call.function.name, arguments: args)))
                        case .rejectedToolCall(let r):
                            diagnostic?("rejected tool call: \(r.reason)")
                            // The model named a real tool that is not declared yet (e.g. web_search before load_skill). Hand the proposal
                            // to the runtime, which loads the owning skill or answers with the schema; it validates and permission-checks.
                            if r.reason == .undeclaredTool || r.reason == .invalidArguments, let name = r.toolName {
                                var p = ToolCallTextParser(idPrefix: request.requestId)
                                var calls = p.feed(r.rawTextPreview).calls; calls += p.finish().calls
                                sawToolCall = true
                                continuation.yield(.toolCall(calls.first { $0.name == name } ?? ToolCall(id: r.callID ?? "\(request.requestId)-r\(name)", name: name, arguments: .object([:]))))
                            }
                        case .info(let i): info = i
                        }
                    }
                    let rest = think.finish()
                    if !rest.reasoning.isEmpty { continuation.yield(.reasoningDelta(rest.reasoning)) }
                    var tail = parser.finish()
                    if !rest.text.isEmpty { let more = parser.feed(rest.text); tail.text = more.text + tail.text; for c in more.calls { sawToolCall = true; continuation.yield(.toolCall(c)) }; tail.text += parser.finish().text }
                    if !tail.text.isEmpty { continuation.yield(.textDelta(tail.text)) }
                    try Task.checkCancellation()
                    guard let info else { throw ProviderError.incompleteStream }
                    continuation.yield(.usage(Usage(promptTokens: info.promptTokenCount, completionTokens: info.generationTokenCount,
                                                    firstTokenLatency: firstToken, tokensPerSecond: info.tokensPerSecond, providerId: id)))
                    continuation.yield(.completed(sawToolCall ? .toolCalls : (info.stopReason == .length ? .length : .stop)))
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: ProviderError.cancelled) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func convert(_ args: [String: MLXLMCommon.JSONValue]) -> AgentRuntime.JSONValue {
        guard let data = try? JSONEncoder().encode(args), let v = try? JSONDecoder().decode(AgentRuntime.JSONValue.self, from: data) else { return .object([:]) }
        return v
    }

    static func schema(_ spec: AgentRuntime.ToolSpec) -> [String: any Sendable] {
        var props: [String: any Sendable] = [:]
        for (k, p) in spec.parameters {
            var d: [String: any Sendable] = ["type": p.kind.rawValue, "description": p.description]
            if let e = p.enumValues { d["enum"] = e }
            props[k] = d
        }
        let required: [String] = spec.parameters.filter(\.value.required).keys.sorted()
        let fn: [String: any Sendable] = ["name": spec.name, "description": spec.description,
            "parameters": ["type": "object", "properties": props, "required": required] as [String: any Sendable]]
        return ["type": "function", "function": fn]
    }

    /// Serializes model access and owns the weights' lifetime.
    actor Engine {
        private var container: ModelContainer?
        var isLoaded: Bool { container != nil }
        private(set) var active = 0
        func begin() { active += 1 }
        func end() { active -= 1 }

        func load(directory: URL, vision: Bool) async throws {
            // MLX keeps freed GPU buffers in a cache that is unbounded by default; on iPhone that cache alone can push the
            // app over its memory limit after a vision turn. 128 MB keeps reuse benefits without the spike.
            MLX.Memory.cacheLimit = 128 * 1024 * 1024
            container = vision
                ? try await VLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
                : try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        func unload() { container = nil; MLX.Memory.clearCache() }

        /// What the model is really sent: chat messages and tool schemas through the model's own chat template and tokenizer.
        private static func userInput(_ request: GenerationRequest, thinking: Bool, tools: [[String: any Sendable]]?) -> UserInput {
            let messages: [Chat.Message] = request.messages.map { m in
                switch m.role {
                case .system: .system(m.text)
                case .user: .user(m.text, images: m.images.map { .url(URL(fileURLWithPath: $0.filePath)) })
                case .assistant: .assistant(m.text, toolCalls: m.toolCalls.isEmpty ? nil : m.toolCalls.map {
                    MLXLMCommon.ToolCall(function: .init(name: $0.name, arguments: ($0.arguments.object ?? [:]).mapValues { MLXProvider.toMLX($0) }), id: $0.id) })
                case .tool: .tool(m.text, id: m.toolCallId)
                }
            }
            // Resize inside the processor too (defence in depth): bounds vision tokens, latency and peak memory.
            return UserInput(chat: messages, processing: .init(maxPixels: VisionLimits.maxPixels), tools: tools, additionalContext: ["enable_thinking": thinking])
        }

        func stream(request: GenerationRequest, thinking: Bool) async throws -> AsyncStream<Generation> {
            guard let container else { throw ProviderError.notPrepared }
            let tools = request.tools.isEmpty ? nil : request.tools.map { MLXModelProvider.schema($0) }
            let params = GenerateParameters(maxTokens: request.maxTokens, temperature: Float(request.temperature))
            return try await container.perform { context in
                let input = Engine.userInput(request, thinking: thinking, tools: tools)
                let prepared = try await context.processor.prepare(input: input)
                return try MLXLMCommon.generate(input: prepared, parameters: params, context: context, tools: tools)
            }
        }

        /// Tokenizes the request exactly as `stream` would, without running the model.
        func countPromptTokens(request: GenerationRequest, thinking: Bool) async throws -> Int {
            guard let container else { throw ProviderError.notPrepared }
            let tools = request.tools.isEmpty ? nil : request.tools.map { MLXModelProvider.schema($0) }
            return try await container.perform { context in
                let input = Engine.userInput(request, thinking: thinking, tools: tools)
                return try await context.processor.prepare(input: input).text.tokens.size
            }
        }
    }
}

enum MLXProvider {
    static func toMLX(_ v: AgentRuntime.JSONValue) -> MLXLMCommon.JSONValue {
        guard let data = try? JSONEncoder().encode(v), let out = try? JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: data) else { return .null }
        return out
    }
}

extension Duration { var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 } }
