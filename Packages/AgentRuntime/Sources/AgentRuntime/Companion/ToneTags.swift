import Foundation

// MARK: - Tone tags (the only source of semantic expression)
//
// A model may begin a segment of its own answer with `[tone:comforting]` (optionally `[tone:comforting:high]`). The tag is
// provider-independent text, so the same protocol works for an on-device model, iTalk's cloud models or anything else that
// follows the instruction. The runner strips it from everything the person sees, hears or stores and reports it as a transient
// event; no extra model request is made and nothing is inferred from the words of the answer. A model that writes no tag, an
// unknown tag or a malformed one produces neutral.

/// One expression marker for the text that follows it.
public struct ToneTag: Sendable, Equatable {
    /// `.neutral` also for labels outside the vocabulary.
    public var intent: CompanionIntent
    public var intensity: Double?
    /// As declared, lowercased (diagnostics only).
    public var label: String
    public var isKnown: Bool

    public init(intent: CompanionIntent, intensity: Double? = nil, label: String, isKnown: Bool) {
        self.intent = intent; self.intensity = intensity; self.label = label; self.isKnown = isKnown
    }
}

/// Payload of the transient `companion.segment` event: where a segment starts and what the model declared for it.
public struct ToneSegment: Codable, Sendable, Equatable {
    public var index: Int
    /// UTF-16 offset in the visible (tag-free) text of this model step.
    public var offset: Int
    /// A `CompanionIntent` raw value; "neutral" when the declaration was unknown.
    public var label: String
    public var intensity: Double?

    public init(index: Int, offset: Int, label: String, intensity: Double? = nil) {
        self.index = index; self.offset = offset; self.label = label; self.intensity = intensity
    }
}

public enum ToneProtocol {
    /// Every intent a model may declare (neutral is the absence of a tag).
    public static let declarable: [CompanionIntent] = CompanionIntent.allCases.filter { $0 != .neutral }

    /// Appended to the system prompt. Describes the reply's own tone only; the model is told not to guess the person's feelings.
    /// Wording chosen by measurement (docs/measurements/companion-cues-*.json): this stricter text made Qwen3.5-2B tag facts less
    /// often and agree more often with the expected tone than the first, shorter one.
    public static var instruction: String {
        let names = declarable.map(\.rawValue).joined(separator: "、")
        return "语气标注（可选，不会显示给用户）：只有当你这一段话本身明显带有某种情绪色彩时，才在这一段开头写 [tone:xxx]，xxx 只能是 \(names) 之一（可加 :low 或 :high）。"
            + "例如安慰别人时写 [tone:comforting]，替人高兴时写 [tone:celebrating]，做不到某事而抱歉时写 [tone:apologetic]。"
            + "事实、数字、定义、步骤和一般性的解释都不要标注，直接回答。标注描述的是你这段话的语气，不是用户的心情；没有把握就不写；不要提到这个标注。"
    }

    static func intensity(forLevel level: String) -> Double? {
        switch level.lowercased() {
        case "low": 0.3
        case "mid", "medium": 0.6
        case "high": 0.9
        default: nil
        }
    }
}

/// Streaming remover of tone tags. Feed it the provider's text deltas; it returns clean text and tags in order. A tag split over
/// any number of deltas is recognized; text is held back only while what follows an opening bracket can still become a tag.
public struct ToneTagFilter: Sendable {
    public enum Piece: Sendable, Equatable {
        case text(String)
        case tag(ToneTag)
    }

    private enum Match { case complete(ToneTag), prefix, none }

    private static let squareOpeners: Set<Character> = ["[", "［", "【", "〔"]
    /// Round brackets only count with the `tone:` key; a bare `(curious)` is ordinary prose (a gloss, a translation).
    private static let openers: Set<Character> = squareOpeners.union(["(", "（"])
    private static let closers: Set<Character> = ["]", "］", "】", "〕", ")", "）"]
    private static let intentNames = CompanionIntent.allCases.map(\.rawValue)
    private static let keySeparators: Set<Character> = [":", "：", "="]
    private static let levelSeparators: Set<Character> = [":", "：", ",", "，", "|", "/", "·"]
    private static let maxLength = 40

    private var held = ""
    private var swallowSpace = false

    public init() {}

    public mutating func feed(_ delta: String) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        for ch in delta {
            if held.isEmpty {
                if swallowSpace { swallowSpace = false; if ch == " " { continue } }
                if Self.openers.contains(ch) { held.append(ch) } else { text.append(ch) }
                continue
            }
            held.append(ch)
            switch Self.match(held) {
            case .complete(let tag):
                if !text.isEmpty { pieces.append(.text(text)); text = "" }
                pieces.append(.tag(tag))
                held = ""; swallowSpace = true
            case .prefix:
                break
            case .none:
                // Release what was held, except a trailing opener, which may start the next candidate.
                var released = held
                held = ""
                if let last = released.last, Self.openers.contains(last) { released.removeLast(); held = String(last) }
                text += released
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// The stream ended: whatever was held back was not a tag.
    public mutating func finish() -> [Piece] {
        defer { held = ""; swallowSpace = false }
        return held.isEmpty ? [] : [.text(held)]
    }

    /// One-shot form for complete texts: the clean text and each tag with the UTF-16 offset in the clean text where it applies.
    public static func strip(_ full: String) -> (text: String, tags: [(offset: Int, tag: ToneTag)]) {
        var filter = ToneTagFilter()
        var text = "", tags: [(offset: Int, tag: ToneTag)] = []
        for piece in filter.feed(full) + filter.finish() {
            switch piece {
            case .text(let t): text += t
            case .tag(let tag): tags.append((text.utf16.count, tag))
            }
        }
        return (text, tags)
    }

    // MARK: Recognition

    /// Keyed form: opener spaces? (`tone` | `语气`) spaces? (`:` | `：` | `=`) spaces? value (spaces? level-separator spaces? level)? spaces? closer.
    /// Bare form, square brackets only (small models drop the key): `[celebrating]`, `[uncertain:low]`, with exactly an intent name.
    private static func match(_ held: String) -> Match {
        let chars = Array(held)
        let n = chars.count
        guard n <= maxLength, let first = chars.first, openers.contains(first) else { return .none }
        let bareAllowed = squareOpeners.contains(first)
        var i = 1
        func skipSpaces() { while i < n, chars[i] == " " || chars[i] == "\u{3000}" { i += 1 } }
        func readLevel() -> String? {                  // nil: more text is needed
            var level = ""
            if levelSeparators.contains(chars[i]) {
                i += 1
                skipSpaces()
                while i < n, chars[i].isLetter { level.append(chars[i]); i += 1 }
                skipSpaces()
                if i == n { return nil }
            }
            return level
        }
        skipSpaces()
        if i == n { return .prefix }
        var key = ""
        while i < n, chars[i].isLetter {
            key.append(chars[i]); i += 1
            let k = key.lowercased()
            let startsKey = "tone".hasPrefix(k) || (k.hasPrefix("tone") && k.count <= 8) || "语气".hasPrefix(k)
            let startsName = bareAllowed && intentNames.contains { $0.hasPrefix(k) }
            if !startsKey && !startsName { return .none }
        }
        if key.isEmpty { return .none }
        let lowered = key.lowercased()
        let exactKey = lowered == "tone" || key == "语气"
        let isKey = exactKey || (lowered.hasPrefix("tone") && lowered.count <= 8)
        let isBare = bareAllowed && intentNames.contains(lowered)
        skipSpaces()
        if i == n { return .prefix }
        if isKey {
            guard keySeparators.contains(chars[i]) else { return .none }
            i += 1
            skipSpaces()
            var value = ""
            while i < n, chars[i].isLetter || chars[i] == "_" || chars[i] == "-" { value.append(chars[i]); i += 1 }
            skipSpaces()
            if i == n { return .prefix }
            guard let level = readLevel() else { return .prefix }
            guard closers.contains(chars[i]), i == n - 1 else { return .none }
            let label = value.lowercased()
            let intent = CompanionIntent(rawValue: label)
            if !exactKey && intent == nil { return .none }              // a loose key ("tones") only counts when the value is an intent
            return .complete(ToneTag(intent: intent ?? .neutral, intensity: intent == nil ? nil : ToneProtocol.intensity(forLevel: level),
                                     label: label, isKnown: intent != nil))
        }
        if isBare {
            guard let level = readLevel() else { return .prefix }
            guard closers.contains(chars[i]), i == n - 1, let intent = CompanionIntent(rawValue: lowered) else { return .none }
            return .complete(ToneTag(intent: intent, intensity: ToneProtocol.intensity(forLevel: level), label: lowered, isKnown: true))
        }
        return .none
    }
}
