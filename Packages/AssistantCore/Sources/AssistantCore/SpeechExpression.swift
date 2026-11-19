import Foundation

public struct SpeechExpressionCue: Equatable, Sendable {
    public let emotion: VoiceEmotion
    public let emphasis: Double
    public init(emotion: VoiceEmotion = .neutral, emphasis: Double = 0.35) {
        self.emotion = emotion
        self.emphasis = emphasis.isFinite ? min(1, max(0, emphasis)) : 0.35
    }
}

/// Per-clause expression of the assistant's own spoken words (never mood recognition, never inferred from keywords).
public struct SpeechExpressionPlan: Sendable {
    public struct Phrase: Sendable {
        public let range: NSRange
        public let cue: SpeechExpressionCue
    }
    public let phrases: [Phrase]
    private let fallback: SpeechExpressionCue

    // CONTEXT MEMORY
    // Updated: 2026-10-31
    // Status: verified
    // Why: Emotion used to be guessed from keyword lists, which the companion brief rules out (a word is not a meaning).
    // Debug Goal: Resolve the current spoken clause using the synthesizer's real UTF-16 position.
    // Search Tags: sentence expression utf16 speech range local emotion companion
    // Invariants:
    // - Plan exactly the normalized text handed to the speech provider.
    // - Emoji and CJK offsets use UTF-16, matching AVSpeechSynthesizer callbacks.
    // - Nothing is inferred from the words: every clause carries the emotion the caller supplies (neutral unless the model declared a
    //   tone for this answer, see CompanionCue / ToneProtocol).
    // Failure Modes:
    // - Character counts misalign phrases containing emoji.
    public init(_ spokenText: String, fallback emotion: VoiceEmotion = .neutral) {
        let cue = SpeechExpressionCue(emotion: emotion)
        fallback = cue
        var result: [Phrase] = []
        var start = 0, position = 0
        for character in spokenText {
            position += String(character).utf16.count
            if "。！？!?；;，,\n".contains(character) {
                result.append(Phrase(range: NSRange(location: start, length: position - start), cue: cue))
                start = position
            }
        }
        if start < position { result.append(Phrase(range: NSRange(location: start, length: position - start), cue: cue)) }
        phrases = result
    }

    public func cue(atUTF16 position: Int) -> SpeechExpressionCue {
        guard position >= 0 else { return fallback }
        return phrases.first { NSLocationInRange(position, $0.range) }?.cue ?? fallback
    }
}
