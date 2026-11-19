import Foundation

/// How finished a Mandarin utterance sounds, from text alone (no model, works offline and on Watch).
public enum Completeness: String, Sendable, Equatable { case complete, neutral, incomplete, hesitating }

public enum MandarinCompletion {
    /// Hesitations, connectors and dangling words after which a speaker usually continues.
    static let continuing = ["嗯", "呃", "额", "唔", "那个", "这个", "就是", "然后", "还有", "而且", "但是", "可是", "不过", "因为", "所以",
                             "如果", "要是", "和", "跟", "或者", "比如", "的话", "先", "再", "我想", "我要", "帮我", "请", "把", "给", "在",
                             "从", "到", "大概", "差不多", "以及", "并且", "另外", "接着", "我是说", "不对", "不是", "我的意思是", "就", "还"]
    /// Pure hesitation sounds: the speaker is still thinking, not done.
    static let fillers = ["嗯", "呃", "额", "唔", "那个", "这个", "就是说"]
    static let finalParticles: Set<Character> = ["吗", "呢", "吧", "了", "啊", "呀", "哦", "嘛", "啦", "哈"]
    /// Lexical endings that close a question or request. ASR punctuation is deliberately ignored: on-device ASR inserts
    /// 「。」「？」 at pauses, so it says nothing reliable about whether the speaker is done.
    static let closingEndings = ["什么", "怎么样", "怎么办", "多少", "几点", "几号", "哪里", "哪儿", "为什么", "是不是", "好不好", "对不对",
                                 "可以吗", "行不行", "有没有", "谢谢", "好的", "没问题", "就这样", "知道了", "明白了"]

    /// Text with punctuation and spaces removed: what the speaker actually said.
    public static func words(_ text: String) -> String { text.filter { !$0.isPunctuation && !$0.isWhitespace && !"…—".contains($0) } }

    /// English (and mixed zh/en) endings, judged on whole WORDS: "understand" must not look like it ends in "and".
    static let enContinuing: Set<String> = ["and", "but", "or", "so", "because", "if", "when", "while", "then", "than", "though", "although", "unless", "until", "since",
                                            "to", "for", "with", "of", "in", "on", "at", "by", "from", "about", "into", "onto", "over", "under", "between", "like",
                                            "the", "a", "an", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these", "those", "some", "any", "every",
                                            "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "can", "could", "will", "would", "should", "may", "might", "must",
                                            "i", "i'm", "i'll", "i'd", "i've", "we", "you", "he", "she", "they", "not", "also", "just", "maybe", "remind", "set", "call", "send", "tell", "show", "make", "add"]
    static let enFillers: Set<String> = ["um", "uh", "er", "erm", "hmm", "hm", "mm", "ah", "well", "so…"]
    static let enClosing: Set<String> = ["please", "thanks", "thank", "okay", "ok", "now", "today", "tomorrow", "tonight", "yesterday", "again", "too", "anymore", "there", "here",
                                         "yes", "no", "yeah", "nope", "sure", "bye", "goodbye", "morning", "evening", "afternoon", "later"]

    /// The last word of the text when it is written in Latin letters (nil when the utterance ends in Chinese).
    static func lastLatinWord(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’"))))
        guard let last = trimmed.last, last.isASCII, last.isLetter || last == "'" || last == "’" else { return nil }
        let word = trimmed.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0 == "'" || $0 == "’")) }).last.map(String.init)
        return word?.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    public static func assess(_ raw: String) -> Completeness {
        let core = words(raw)
        guard core.count >= 2 else { return .incomplete }
        if let word = lastLatinWord(raw) {
            let count = raw.split(whereSeparator: { $0.isWhitespace }).count
            if enFillers.contains(word) || raw.hasSuffix("…") || raw.hasSuffix("...") { return .hesitating }
            if let last = raw.trimmingCharacters(in: .whitespaces).last, ",".contains(last) { return .incomplete }
            if enContinuing.contains(word) { return .incomplete }
            if enClosing.contains(word) && count >= 2 { return .complete }
            return count < 3 ? .incomplete : .neutral
        }
        if let last = raw.trimmingCharacters(in: .whitespaces).last, "，,、—".contains(last) { return .incomplete }
        if fillers.contains(where: { core.hasSuffix($0) }) || raw.hasSuffix("…") || raw.hasSuffix("...") { return .hesitating }
        if continuing.contains(where: { core.hasSuffix($0) }) { return .incomplete }
        if let last = core.last, finalParticles.contains(last), core.count >= 3 { return .complete }
        if closingEndings.contains(where: { core.hasSuffix($0) }) { return .complete }
        // Very short fragments (「我昨天晚上」) usually continue.
        return core.count < 6 ? .incomplete : .neutral
    }
}

/// Adaptive end-of-turn detection. A pause is measured from the last *voice activity* (VAD) or the last time new *words*
/// appeared; ASR revisions that only change punctuation or segmentation do not restart the clock.
public struct TurnDetector: Sendable {
    public struct Config: Sendable, Equatable {
        public var silenceComplete: TimeInterval = 0.55
        public var silenceNeutral: TimeInterval = 0.9
        public var silenceIncomplete: TimeInterval = 1.7
        public var maxSilence: TimeInterval = 2.5
        public var noSpeechTimeout: TimeInterval = 8
        public var maxTurn: TimeInterval = 60
        public init() {}
    }
    public enum Decision: Equatable, Sendable {
        case listening
        case endOfTurn(reason: String)
        case noSpeech
        case maxDuration
    }

    public private(set) var config: Config
    public private(set) var transcript = ""
    private var spokenWords = ""
    private var startedAt: Date
    private var lastVoiceAt: Date?
    private var lastWordsAt: Date?
    private var voiceActive = false
    private var pauseStartedAt: Date?
    /// Pauses (seconds) that the user later continued after: learned per session, used to stretch the wait.
    public private(set) var observedPauses: [TimeInterval] = []
    /// When silence (the pause that ended the turn) began; for latency measurement.
    public var silenceStartedAt: Date? { [lastVoiceAt, lastWordsAt].compactMap { $0 }.max() }

    public init(config: Config = .init(), start: Date = .now, learnedPauses: [TimeInterval] = []) {
        self.config = config; startedAt = start; observedPauses = learnedPauses
    }

    public mutating func voice(active: Bool, at t: Date) {
        if active {
            if let p = pauseStartedAt, lastVoiceAt != nil {
                let pause = t.timeIntervalSince(p)
                if pause >= 0.3 { observedPauses.append(pause); if observedPauses.count > 20 { observedPauses.removeFirst() } }
            }
            pauseStartedAt = nil; lastVoiceAt = t
        } else if voiceActive {
            pauseStartedAt = t; lastVoiceAt = t
        }
        voiceActive = active
    }

    public mutating func transcript(_ text: String, at t: Date) {
        transcript = text
        let w = MandarinCompletion.words(text)
        // Only growth in actual words is evidence of speech; revisions/finalization are not.
        if w.count > spokenWords.count { lastWordsAt = t }
        spokenWords = w
    }

    public func requiredSilence() -> TimeInterval {
        let base: TimeInterval = switch MandarinCompletion.assess(transcript) {
        case .complete: config.silenceComplete
        case .neutral: config.silenceNeutral
        case .incomplete: config.silenceIncomplete
        case .hesitating: config.maxSilence
        }
        guard observedPauses.count >= 2 else { return base }
        let sorted = observedPauses.sorted()
        let p80 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.8))]
        // A speaker who pauses a lot mid-sentence gets a little more room, but never more than maxSilence.
        return min(config.maxSilence, max(base, min(p80 + 0.2, base * 2)))
    }

    public func decide(at t: Date) -> Decision {
        let elapsed = t.timeIntervalSince(startedAt)
        if elapsed >= config.maxTurn { return .maxDuration }
        guard !spokenWords.isEmpty else { return elapsed >= config.noSpeechTimeout ? .noSpeech : .listening }
        if voiceActive { return .listening }
        let silence = t.timeIntervalSince(silenceStartedAt ?? startedAt)
        let needed = requiredSilence()
        return silence >= needed ? .endOfTurn(reason: "silence \(String(format: "%.2f", silence))s ≥ \(String(format: "%.2f", needed))s (\(MandarinCompletion.assess(transcript).rawValue))") : .listening
    }
}

/// Energy VAD with an adaptive noise floor: fallback when the system speech detector is unavailable.
public struct EnergyVAD: Sendable {
    public private(set) var noiseFloorDB: Double = -60
    public private(set) var active = false
    private var aboveFrames = 0, belowFrames = 0, frames = 0
    public var onsetFrames = 2, hangoverFrames = 5, marginDB = 10.0
    public init() {}
    /// - Parameter levelDB: RMS level of one ~100 ms buffer, in dBFS.
    public mutating func process(levelDB: Double) -> Bool {
        // Floor follows quiet passages quickly and loud ones slowly, so speech does not raise it.
        frames += 1
        if frames <= 5 { noiseFloorDB = frames == 1 ? levelDB : min(noiseFloorDB, levelDB); return false }   // warm-up: learn the room
        if levelDB < noiseFloorDB { noiseFloorDB = noiseFloorDB * 0.7 + levelDB * 0.3 }
        else if !active { noiseFloorDB = noiseFloorDB * 0.9 + levelDB * 0.1 }       // room got louder (fan, street)
        else { noiseFloorDB = noiseFloorDB * 0.999 + levelDB * 0.001 }
        if levelDB > noiseFloorDB + marginDB { aboveFrames += 1; belowFrames = 0 } else { belowFrames += 1; aboveFrames = 0 }
        if !active && aboveFrames >= onsetFrames { active = true }
        if active && belowFrames >= hangoverFrames { active = false }
        return active
    }
}
