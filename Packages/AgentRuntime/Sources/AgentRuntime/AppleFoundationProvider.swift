#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device system model through the shared `ModelProvider` contract (iOS 26 API surface only).
/// Declared chat-only: tools are not bridged, so the runtime treats it like a small local model.
/// Availability depends on device, region, language and Apple Intelligence settings — never the only free path.
@available(iOS 26.0, macOS 26.0, *)
public final class AppleFoundationProvider: ModelProvider, @unchecked Sendable {
    public let descriptor = ModelDescriptor(
        id: "apple.foundation", kind: .appleFoundation, displayName: "Apple 设备端模型",
        capabilities: ProviderCapabilities(contextWindow: 4096, streaming: true, toolCalling: .none, structuredOutput: false,
                                           maxAutonomy: .chatOnly, worksOffline: true, sendsContentOffDevice: false))
    public init() {}

    public enum Availability: Equatable, Sendable { case available, unavailable(String) }
    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(let reason): .unavailable("\(reason)")
        }
    }

    public func prepare(progress: @Sendable (PreparationState) -> Void) async throws {
        progress(.checkingResources)
        guard case .available = Self.availability, case .available = SystemLanguageModel.default.availability else {
            progress(.failed("Apple 设备端模型不可用")); throw ProviderError.unsupported("apple foundation model unavailable")
        }
        progress(.ready)
    }
    public func unload() async {}

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n")
                    let session = LanguageModelSession(instructions: system)
                    // Fold history into one prompt; the system model has a small context, so keep the most recent turns.
                    let transcript = request.messages.filter { $0.role != .system }.suffix(8).map { ($0.role == .user ? "用户：" : "助手：") + $0.text }.joined(separator: "\n")
                    let started = ContinuousClock.now
                    var shown = "", first: Double?
                    for try await snapshot in session.streamResponse(to: transcript) {
                        try Task.checkCancellation()
                        let full = snapshot.content
                        guard full.hasPrefix(shown), full.count > shown.count else { continue }
                        if first == nil { let d = ContinuousClock.now - started; first = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
                        continuation.yield(.textDelta(String(full.dropFirst(shown.count))))
                        shown = full
                    }
                    continuation.yield(.usage(Usage(completionTokens: 0, firstTokenLatency: first, providerId: "apple.foundation")))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: ProviderError.cancelled) }
                catch { continuation.finish(throwing: ProviderError.failed("\(error)")) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
