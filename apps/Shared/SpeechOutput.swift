import AVFoundation
import Foundation
import AssistantCore

/// On-device speech output (Apple system voices). Replaceable provider: it speaks `SpokenText` chunks, never raw display text.
/// Quality depends on which Mandarin voices are installed: Premium/Enhanced voices (Settings › Accessibility › Spoken Content ›
/// Voices › Chinese) sound far more natural than the compact default.
@MainActor final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    struct VoiceOption: Identifiable, Hashable {
        let id: String, name: String, language: String, quality: AVSpeechSynthesisVoiceQuality
        var qualityLabel: String { switch quality { case .premium: "高级"; case .enhanced: "增强"; default: "标准" } }
    }
    /// Styles this provider can render. System voices have no emotion control, so styles are prosody presets only
    /// (rate/pitch); anything beyond these is not offered.
    static let supportedStyles: Set<SpeechStyle> = [.neutral, .calm, .cheerful]

    static let voiceKey = "italk.voice.id", rateKey = "italk.voice.rate", styleKey = "italk.voice.style"

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var pending: Set<ObjectIdentifier> = []
    private var lastUtterance: ObjectIdentifier?
    private var wordActivity: (() -> Void)?
    private var expressionActivity: ((SpeechExpressionCue) -> Void)?
    private var expressionPlans: [ObjectIdentifier: SpeechExpressionPlan] = [:]
    private var lastExpression: SpeechExpressionCue?
    override init() { super.init(); synthesizer.delegate = self }

    /// Installed Mandarin voices, best quality first.
    static func mandarinVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" || $0.language == "zh-TW" }
            .map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality) }
            .sorted { ($0.language == "zh-CN" ? 0 : 1, -$0.quality.rawValue, $0.name) < ($1.language == "zh-CN" ? 0 : 1, -$1.quality.rawValue, $1.name) }
    }
    static var preferredVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return mandarinVoices().first.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) } ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }
    static var userStyle: SpeechStyle? { UserDefaults.standard.string(forKey: styleKey).flatMap(SpeechStyle.init(rawValue:)) }

    func stop() {
        completion = nil; wordActivity = nil; expressionActivity = nil; expressionPlans = [:]; lastExpression = nil
        pending = []; lastUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String, style: SpeechStyle = .neutral, voiceOverride: String? = nil,
               emotion: VoiceEmotion = .neutral, onExpression: @escaping (SpeechExpressionCue) -> Void = { _ in },
               onWord: @escaping () -> Void = {}, completed: @escaping () -> Void) throws {
        stop()
        guard let voice = voiceOverride.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.preferredVoice else { throw AppFailure.message("请在系统中安装普通话语音后重试。") }
        let chunks = SpokenText.chunks(text)
        guard !chunks.isEmpty else { completed(); return }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio, options: [])
        try audio.setActive(true)
        completion = completed; wordActivity = onWord; expressionActivity = onExpression
        let base = UserDefaults.standard.object(forKey: Self.rateKey) as? Float ?? AVSpeechUtteranceDefaultSpeechRate
        let (rateScale, pitch): (Float, Float) = switch Self.supportedStyles.contains(style) ? style : .neutral {
        case .calm: (0.92, 0.96)
        case .cheerful: (1.05, 1.08)
        default: (1.0, 1.0)
        }
        for (i, chunk) in chunks.enumerated() {
            let u = AVSpeechUtterance(string: chunk)
            u.voice = voice
            u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, base * rateScale))
            u.pitchMultiplier = pitch
            // Natural pause between sentences; a little longer after questions and paragraph ends.
            u.postUtteranceDelay = i == chunks.count - 1 ? 0 : (chunk.hasSuffix("？") || chunk.hasSuffix("\n") ? 0.28 : 0.16)
            let key = ObjectIdentifier(u)
            pending.insert(key); lastUtterance = key
            expressionPlans[key] = SpeechExpressionPlan(chunk, fallback: emotion)
            synthesizer.speak(u)
        }
    }

    /// Short preview for the voice picker.
    func preview(voiceID: String, completed: @escaping () -> Void = {}) {
        try? speak("你好，我是 iTalk。今天下午3:30提醒你开会。", voiceOverride: voiceID, completed: completed)
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-26
    // Status: inferred
    // Why: Facial expressions must follow the clause actually being spoken, not a repeating bounce.
    // Debug Goal: Publish expression and word events only for the answer still playing.
    // Search Tags: speech expression clause callback stop cancellation stale utterance
    // Invariants:
    // - Delegate callbacks cross to MainActor and check the utterance belongs to the current answer.
    // - Stop clears state before stopping synthesis; old speech cannot animate or complete a new turn.
    // - Use actual normalized utterance UTF-16 ranges, not estimated speech timing.
    // Failure Modes:
    // - Whole-answer emotion stays fixed while subsequent clauses change intent.
    // - Late delegate callbacks change a new turn's face after cancellation.
    private func publishExpression(_ id: ObjectIdentifier, position: Int) {
        guard pending.contains(id), let plan = expressionPlans[id] else { return }
        let cue = plan.cue(atUTF16: position)
        guard cue != lastExpression else { return }
        lastExpression = cue; expressionActivity?(cue)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.publishExpression(key, position: 0) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let spokenID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.pending.contains(spokenID) else { return }
            self.publishExpression(spokenID, position: characterRange.location)
            self.wordActivity?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let completedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.pending.remove(completedID) != nil else { return }
            self.expressionPlans[completedID] = nil
            guard completedID == self.lastUtterance else { return }
            self.wordActivity = nil; self.expressionActivity = nil; self.lastExpression = nil; self.lastUtterance = nil
            let complete = self.completion; self.completion = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            complete?()
        }
    }
}
