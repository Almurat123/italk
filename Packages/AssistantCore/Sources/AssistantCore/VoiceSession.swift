import Foundation

public enum VoicePhase: String, Codable, Sendable {
    case idle, preparing, listening, finalizing, thinking, synthesizing, confirming, speaking, interrupted, failed

    public var label: String {
        switch self {
        case .idle: "随时听你说"
        case .preparing: "正在准备"
        case .listening: "正在听"
        case .finalizing: "正在识别"
        case .thinking: "正在思考"
        case .synthesizing: "正在合成语音"
        case .confirming: "请确认"
        case .speaking: "正在回答"
        case .interrupted: "已暂停"
        case .failed: "需要处理一下"
        }
    }
}

public struct VoiceSession: Sendable {
    public private(set) var generation: UUID = UUID()
    public private(set) var phase: VoicePhase = .idle
    public private(set) var transcript = ""
    public private(set) var answer = ""
    public private(set) var stages: [String: TimeInterval] = [:]
    private var began: Date = .now

    public init() {}

    // CONTEXT MEMORY
    // Updated: 2026-10-25
    // Status: verified
    // Why: Cancelled ASR and network tasks can still deliver callbacks.
    // Debug Goal: A previous turn must never mutate or speak in the current turn.
    // Search Tags: stale voice generation half duplex capture playback
    // Invariants:
    // - Every callback is bound to a generation.
    // - Transcript is accepted only while listening or finalizing.
    // Failure Modes:
    // - Cancelled results overwrite a newer answer.
    // - Assistant playback becomes a new user transcript.
    @discardableResult public mutating func begin(now: Date = .now) -> UUID {
        generation = UUID()
        phase = .preparing
        transcript = ""
        answer = ""
        stages = [:]
        began = now
        return generation
    }

    @discardableResult public mutating func transition(_ next: VoicePhase, for id: UUID, now: Date = .now) -> Bool {
        guard id == generation else { return false }
        let allowed: [VoicePhase: Set<VoicePhase>] = [
            .idle: [.preparing], .preparing: [.listening, .thinking, .failed, .interrupted],
            .listening: [.finalizing, .failed, .interrupted],
            .finalizing: [.thinking, .failed, .interrupted],
            .thinking: [.confirming, .synthesizing, .speaking, .idle, .failed, .interrupted],
            .synthesizing: [.speaking, .idle, .failed, .interrupted],
            .confirming: [.thinking, .idle, .failed, .interrupted],
            .speaking: [.idle, .failed, .interrupted],
            .failed: [.idle], .interrupted: [.idle]
        ]
        guard allowed[phase, default: []].contains(next) else { return false }
        phase = next
        stages[next.rawValue] = now.timeIntervalSince(began)
        return true
    }

    public mutating func receiveTranscript(_ text: String, for id: UUID) {
        guard generation == id, phase == .listening || phase == .finalizing else { return }
        transcript = text
    }

    public mutating func receiveAnswer(_ text: String, for id: UUID) {
        guard generation == id, phase == .thinking || phase == .speaking else { return }
        answer = text
    }

    public mutating func cancel() {
        generation = UUID()
        phase = .idle
    }
}

public struct EndpointPolicy: Sendable {
    public var silence: TimeInterval = 1.2
    public var noSpeech: TimeInterval = 8
    public var maximum: TimeInterval = 60
    public init() {}

    public func shouldFinish(elapsed: TimeInterval, sinceSpeech: TimeInterval, hasText: Bool) -> Bool {
        elapsed >= maximum || (hasText ? sinceSpeech >= silence : elapsed >= noSpeech)
    }
}
