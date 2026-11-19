import Foundation

/// Splits a raw local-model token stream into display-safe text and complete tool-call proposals.
/// Qwen-style `<tool_call>{json}</tool_call>` blocks are consumed here, so tool JSON never reaches the
/// screen or text-to-speech. An unterminated block at end of stream is discarded and reported.
public struct ToolCallTextParser: Sendable {
    public struct Output: Sendable, Equatable {
        public var text = ""
        public var calls: [ToolCall] = []
        public var malformed = 0
    }
    private static let open = "<tool_call>", close = "</tool_call>"
    private var buffer = ""
    private var insideCall = false
    private var counter = 0
    private let idPrefix: String
    public init(idPrefix: String = "call") { self.idPrefix = idPrefix }

    public mutating func feed(_ chunk: String) -> Output {
        buffer += chunk
        var out = Output()
        while true {
            if insideCall {
                guard let end = buffer.range(of: Self.close) else { return out }
                let body = String(buffer[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[end.upperBound...]); insideCall = false
                if let call = parse(body) { out.calls.append(call) } else { out.malformed += 1 }
            } else if let start = buffer.range(of: Self.open) {
                out.text += buffer[..<start.lowerBound]
                buffer = String(buffer[start.upperBound...]); insideCall = true
            } else {
                // Hold back a possible partial opening tag at the end of the buffer.
                let keep = Self.partialSuffix(of: buffer)
                out.text += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                return out
            }
        }
    }

    public mutating func finish() -> Output {
        var out = Output()
        if insideCall { out.malformed += 1 } else { out.text = buffer }
        buffer = ""; insideCall = false
        return out
    }

    private mutating func parse(_ body: String) -> ToolCall? {
        guard let json = JSONValue.parse(body), let name = json["name"]?.string, !name.isEmpty else { return nil }
        counter += 1
        return ToolCall(id: "\(idPrefix)-\(counter)", name: name, arguments: json["arguments"] ?? .object([:]))
    }

    private static func partialSuffix(of s: String) -> Int {
        for n in stride(from: min(open.count - 1, s.count), to: 0, by: -1) where open.hasPrefix(String(s.suffix(n))) { return n }
        return 0
    }
}
