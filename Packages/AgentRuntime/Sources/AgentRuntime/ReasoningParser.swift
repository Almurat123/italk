import Foundation

/// Splits a model's text stream into reasoning (`<think>…</think>`) and answer, across arbitrary chunk boundaries.
/// With thinking mode on, Qwen-style templates open the block in the prompt, so output starts *inside* reasoning.
public struct ReasoningTextParser: Sendable {
    public struct Output: Sendable, Equatable { public var text = ""; public var reasoning = "" }
    private var inside: Bool
    private var pending = ""
    private var trimAnswerLead = false
    private static let open = "<think>", close = "</think>"

    public init(startsInside: Bool = false) { inside = startsInside }

    public mutating func feed(_ chunk: String) -> Output {
        pending += chunk
        var out = Output()
        while true {
            let tag = inside ? Self.close : Self.open
            if let r = pending.range(of: tag) {
                let before = String(pending[..<r.lowerBound])
                if inside { out.reasoning += before } else { out.text += before }
                pending = String(pending[r.upperBound...])
                if inside { trimAnswerLead = true }
                inside.toggle()
                continue
            }
            // Hold back a trailing partial tag ("</thi") until the next chunk decides what it is.
            var keep = 0
            for n in stride(from: min(tag.count - 1, pending.count), through: 1, by: -1) where pending.hasSuffix(String(tag.prefix(n))) { keep = n; break }
            let emit = String(pending.dropLast(keep))
            pending = String(pending.suffix(keep))
            if inside { out.reasoning += emit } else { out.text += emit }
            break
        }
        if trimAnswerLead, !inside, !out.text.isEmpty {
            out.text = String(out.text.drop { $0 == "\n" || $0 == " " })
            if !out.text.isEmpty { trimAnswerLead = false }
        }
        return out
    }

    public mutating func finish() -> Output {
        var out = Output()
        if inside { out.reasoning = pending } else { out.text = pending }
        pending = ""
        return out
    }
}
