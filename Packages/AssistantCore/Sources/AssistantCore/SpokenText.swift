import Foundation

/// Turns an assistant answer (display text) into speakable Mandarin chunks. Display text and spoken text are separate:
/// nothing here changes what is shown, and no Markdown, code, JSON, URLs or tool traces are ever read aloud.
public enum SpokenText {
    /// Sentence-sized chunks, each ≤ `maxChunk` characters, in order.
    public static func chunks(_ display: String, maxChunk: Int = 60) -> [String] {
        let clean = normalize(strip(display))
        var out: [String] = [], current = ""
        for ch in clean {
            current.append(ch)
            if "。！？；!?;\n".contains(ch) || (current.count >= maxChunk && "，、,".contains(ch)) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }
        return out
    }

    /// Removes markup that must not be spoken.
    public static func strip(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "（代码已省略）", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\{[^{}]*"[^{}]*\}"#, with: "", options: .regularExpression)              // inline JSON
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: "$1", options: .regularExpression)  // [text](url)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "链接", options: .regularExpression)
        for (a, b) in [("\\times", "乘"), ("\\div", "除以"), ("$$", ""), ("$", ""), ("**", ""), ("__", ""), ("`", ""), ("#", ""), (">", "")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: #"(?m)^\s*([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        return t
    }

    /// Mandarin reading of numbers in common patterns. The synthesizer handles plain integers; these are the cases it reads wrong.
    public static func normalize(_ s: String) -> String {
        var t = s
        func sub(_ pattern: String, _ f: ([String]) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = t as NSString
            var result = "", last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
                result += f(groups); last = m.range.location + m.range.length
            }
            result += ns.substring(from: last); t = result
        }
        sub(#"(\d{1,2})[:：](\d{2})"#) { g in "\(cn(Int(g[1])!))点" + (Int(g[2])! == 0 ? "" : (g[2].hasPrefix("0") ? "零" : "") + "\(cn(Int(g[2])!))分") }
        sub(#"(\d{4})年"#) { g in g[1].map { digit($0) }.joined() + "年" }                                      // 2026年 → 二零二六年
        sub(#"(\d{1,2})/(\d{1,2})(?!\d)"#) { g in "\(cn(Int(g[1])!))月\(cn(Int(g[2])!))日" }
        sub(#"(-?\d+(?:\.\d+)?)\s*[%％]"#) { g in "百分之" + number(g[1]) }
        sub(#"(-?\d+(?:\.\d+)?)\s*(°C|℃)"#) { g in number(g[1]) + "摄氏度" }
        sub(#"(\d+(?:\.\d+)?)\s*[-~～到至]\s*(\d+(?:\.\d+)?)"#) { g in number(g[1]) + "到" + number(g[2]) }
        let units = ["km": "公里", "kg": "公斤", "cm": "厘米", "mm": "毫米", "ml": "毫升", "mg": "毫克", "kcal": "千卡", "bpm": "次每分钟", "g": "克", "m": "米"]
        sub(#"(\d+(?:\.\d+)?)\s*(kcal|bpm|km|kg|cm|mm|ml|mg|g|m)\b"#) { g in number(g[1]) + (units[g[2].lowercased()] ?? g[2]) }
        sub(#"(?<![\d.])(\d+\.\d+)(?![\d.])"#) { g in number(g[1]) }                                           // 3.5 → 三点五
        sub(#"(?<!\d)(1\d{10})(?!\d)"#) { g in g[1].map { $0 == "1" ? "幺" : digit($0) }.joined() }                // phone numbers
        return t
    }

    static func digit(_ c: Character) -> String { ["0": "零", "1": "一", "2": "二", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"][c] ?? String(c) }

    static func number(_ s: String) -> String {
        var t = s, sign = ""
        if t.hasPrefix("-") { sign = "负"; t.removeFirst() }
        let parts = t.split(separator: ".", maxSplits: 1)
        guard let whole = Int(parts[0]) else { return s }
        var out = sign + cn(whole)
        if parts.count == 2 { out += "点" + parts[1].map { digit($0) }.joined() }
        return out
    }

    /// Integer → Chinese numerals (0 … 99,999,999), with 两 handled by the synthesizer's own reading.
    public static func cn(_ n: Int) -> String {
        if n == 0 { return "零" }
        if n >= 100_000_000 { return String(n) }
        if n >= 10_000 {
            let high = n / 10_000, low = n % 10_000
            return cn(high) + "万" + (low == 0 ? "" : (low < 1000 ? "零" : "") + cn(low))
        }
        let units = ["", "十", "百", "千"]
        var digits = String(n).map { digit($0) }, out = "", zero = false
        let count = digits.count
        for (i, d) in digits.enumerated() {
            let pos = count - 1 - i
            if d == "零" { zero = true; continue }
            if zero { out += "零"; zero = false }
            out += d + units[pos]
        }
        if out.hasPrefix("一十") { out.removeFirst() }      // 十二, not 一十二
        digits.removeAll()
        return out
    }
}

/// Requested delivery style. A provider exposes only the styles it can actually render (`SpeechCapabilities`).
public enum SpeechStyle: String, Codable, CaseIterable, Sendable {
    case neutral, warm, calm, cheerful, empathetic, curious, serious
    public var label: String {
        switch self { case .neutral: "自然"; case .warm: "温暖"; case .calm: "平静"; case .cheerful: "轻快"; case .empathetic: "体贴"; case .curious: "好奇"; case .serious: "认真" }
    }
    /// Resolution order: explicit user choice wins; health/consequential content is spoken neutrally for clarity;
    /// otherwise the reply's delivery intent, falling back to neutral when the provider cannot render it.
    public static func resolve(userChoice: SpeechStyle?, intent: VoiceEmotion, consequential: Bool, supported: Set<SpeechStyle>) -> SpeechStyle {
        if let userChoice, supported.contains(userChoice) { return userChoice }
        if consequential { return .neutral }
        let wanted: SpeechStyle = switch intent {
        case .neutral: .neutral; case .happy: .cheerful; case .calm: .calm; case .sad: .empathetic; case .curious: .curious; case .serious: .serious
        }
        return supported.contains(wanted) ? wanted : .neutral
    }
}

/// A voice the user may later create from their own recordings. Creation requires the voice owner's explicit, recorded
/// consent; no profile can be made from arbitrary imported audio. Voice cloning itself is NOT shipped yet (no model has been
/// verified on iPhone); this is the storage/consent contract it will use.
public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable {
    public enum Processing: String, Codable, Sendable { case onDevice, cloud }
    public var id: UUID
    public var displayName: String
    public var processing: Processing
    public var consent: VoiceConsent
    public var createdAt: Date
    /// Relative paths of reference recordings inside the app's protected container (never synced, deleted with the profile).
    public var referenceRecordings: [String]
}

public struct VoiceConsent: Codable, Sendable, Equatable {
    /// The statement the owner read aloud, e.g. 「我同意 iTalk 用我的声音为我自己生成语音。」
    public var statement: String
    /// ASR transcript of the owner's recorded statement; must match `statement` (see `isValid`).
    public var spokenTranscript: String
    public var ownerConfirmedSelf: Bool
    public var cloudDisclosureAccepted: Bool
    public var recordedAt: Date

    public static let requiredStatement = "我同意 iTalk 用我的声音为我自己生成语音"

    /// Live recording of the statement by the owner, the self-confirmation, and (for cloud processing) the transmission disclosure.
    public func isValid(for processing: VoiceProfile.Processing) -> Bool {
        let norm: (String) -> String = { $0.filter { !$0.isPunctuation && !$0.isWhitespace } }
        return ownerConfirmedSelf && norm(spokenTranscript).contains(norm(statement)) && norm(statement) == norm(Self.requiredStatement)
            && (processing == .onDevice || cloudDisclosureAccepted)
    }
}

/// Releases stable spoken chunks from a growing (streamed) answer. Text is only released once a sentence boundary has been
/// generated after it, so nothing still being written is spoken. The first chunk may be cut at a comma to start audio early;
/// very short sentences are merged so playback has no choppy gaps.
public struct StreamingSpeechSplitter: Sendable {
    /// The first phrase is released at its first comma once it has this many characters (time-to-first-audio).
    public var firstChunkMinCharacters = 4
    /// …or, with no punctuation yet, cut at this length so the voice never waits for a long first sentence.
    public var firstChunkMaxCharacters = 22
    /// Later phrases also split at a comma once this long (keeps synthesis ahead of playback for long sentences).
    public var laterCommaSplit = 26
    public var mergeBelow = 6
    private var consumed = 0            // characters of the cleaned text already released
    private var released = 0
    public init() {}

    /// Feed the cumulative answer so far; returns newly stable chunks (already stripped/normalized for speech).
    public mutating func update(_ cumulative: String) -> [String] { take(from: cumulative, final: false).map(\.text) }
    /// The answer is complete: returns everything not yet released.
    public mutating func finish(_ full: String) -> [String] { take(from: full, final: true).map(\.text) }

    /// A chunk released for speech and where its source begins in the cumulative text that was fed.
    public struct Chunk: Sendable, Equatable {
        public var text: String
        /// Characters of the cumulative text before the source of this chunk (the unit `TextSanitizer.plain` output is counted in).
        public var sourceStart: Int
        public init(text: String, sourceStart: Int) { self.text = text; self.sourceStart = sourceStart }
    }
    /// Same as `update`, with each chunk's start offset (used to follow the spoken position through the answer's segments).
    public mutating func updateChunks(_ cumulative: String) -> [Chunk] { take(from: cumulative, final: false) }
    public mutating func finishChunks(_ full: String) -> [Chunk] { take(from: full, final: true) }

    /// The text being fed starts over (a new model step after a tool step restarts its cumulative text at zero). Releases whatever
    /// `previous` still held back, then counts from the first character again; without this the new text would be skipped up to the
    /// old offset, or not spoken at all while it is shorter than that.
    public mutating func restart(flushing previous: String) -> [Chunk] {
        let rest = take(from: previous, final: true)
        consumed = 0; released = 0
        return rest
    }

    private mutating func take(from text: String, final: Bool) -> [Chunk] {
        let chars = Array(text)
        guard consumed <= chars.count else { return [] }
        var out: [(piece: String, start: Int)] = []
        var start = consumed, i = consumed
        while i < chars.count {
            let c = chars[i]
            let hardStop = "。！？；!?;\n".contains(c)
            let first = released == 0 && out.isEmpty
            let comma = "，,、：:".contains(c)
            let softStop = comma && (i - start + 1) >= (first ? firstChunkMinCharacters : laterCommaSplit)
            let lengthCap = first && !final && (i - start + 1) >= firstChunkMaxCharacters
            if hardStop || softStop || lengthCap {
                let piece = String(chars[start...i])
                if SpokenText.strip(piece).trimmingCharacters(in: .whitespacesAndNewlines).count < (first ? firstChunkMinCharacters : mergeBelow), i + 1 < chars.count || !final {
                    i += 1; continue                                   // too short: merge with what follows
                }
                out.append((piece, start)); start = i + 1
            }
            i += 1
        }
        if final, start < chars.count { out.append((String(chars[start...]), start)); start = chars.count }
        consumed = start
        let spoken = out.compactMap { item -> Chunk? in
            let spokenText = SpokenText.normalize(SpokenText.strip(item.piece)).trimmingCharacters(in: .whitespacesAndNewlines)
            return spokenText.isEmpty ? nil : Chunk(text: spokenText, sourceStart: item.start)
        }
        released += spoken.count
        return spoken
    }
}
