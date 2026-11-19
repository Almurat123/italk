import Foundation

/// Deterministic provider for replay tests and UI previews. Never counts as real-model integration.
public final class ScriptedModelProvider: ModelProvider, @unchecked Sendable {
    public struct Step: Sendable {
        public var events: [GenerationEvent]
        public var error: ProviderError?
        public var delayMs: Int
        public init(_ events: [GenerationEvent], error: ProviderError? = nil, delayMs: Int = 0) { self.events = events; self.error = error; self.delayMs = delayMs }
    }
    public let descriptor: ModelDescriptor
    private let lock = NSLock()
    private var steps: [Step]
    private var _requests: [GenerationRequest] = []
    public init(descriptor: ModelDescriptor, steps: [Step]) { self.descriptor = descriptor; self.steps = steps }
    public var requests: [GenerationRequest] { lock.withLock { _requests } }
    public func prepare(progress: @Sendable (PreparationState) -> Void) async throws { progress(.ready) }
    public func unload() async {}
    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let step: Step? = lock.withLock { _requests.append(request); return steps.isEmpty ? nil : steps.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let step else { continuation.finish(throwing: ProviderError.failed("script exhausted")); return }
                for e in step.events {
                    if step.delayMs > 0 { try? await Task.sleep(for: .milliseconds(step.delayMs)) }
                    if Task.isCancelled { continuation.finish(throwing: ProviderError.cancelled); return }
                    continuation.yield(e)
                }
                continuation.finish(throwing: step.error)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension ModelDescriptor {
    static func scripted(id: String = "scripted", kind: ProviderKind = .localDownloaded, autonomy: AutonomyLevel = .fullAgent, tools: ToolCallingLevel = .native, offline: Bool = true) -> ModelDescriptor {
        ModelDescriptor(id: id, kind: kind, displayName: id, capabilities: ProviderCapabilities(contextWindow: 4096, toolCalling: tools, structuredOutput: false, maxAutonomy: autonomy, worksOffline: offline, sendsContentOffDevice: !offline))
    }
}
