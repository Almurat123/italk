import Foundation
import AssistantCore

@MainActor final class SpeechInput {
    var echoCancelled: Bool { false }
    var recognizerReady: Bool { false }
    func start(duplex: Bool = false, preferEchoCancellation: Bool = true, onText: @escaping @MainActor (String) -> Void, onActivity: @escaping @MainActor () -> Void, onError: @escaping @MainActor (Error) -> Void, onLevel: @escaping @MainActor (Double) -> Void = { _ in }, onStage: @escaping @MainActor (CaptureStage) -> Void = { _ in }) async throws {
        throw AppFailure.message("Watch 的独立语音识别尚未接通。当前可使用系统听写输入，直接连接已配置的 HTTPS 网关。")
    }
    func finish() async throws {}
    func cancel() async {}
}
