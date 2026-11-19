import Foundation

/// Delivery intent for the assistant's own reply, never a diagnosis of the user's mood.
public enum VoiceEmotion: String, Codable, CaseIterable, Sendable {
    case neutral, happy, calm, sad, curious, serious
    public var label: String {
        switch self {
        case .neutral: "自然"
        case .happy: "开心"
        case .calm: "温柔"
        case .sad: "低落"
        case .curious: "好奇"
        case .serious: "认真"
        }
    }
}
