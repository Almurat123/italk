import Foundation

/// Turns model output into plain text that is safe to show and to read aloud: no Markdown emphasis, code fences or LaTeX markers.
public enum TextSanitizer {
    public static func plain(_ text: String) -> String {
        var s = text
        for (from, to) in [("\\times", "×"), ("\\div", "÷"), ("\\cdot", "·"), ("\\left", ""), ("\\right", ""), ("\\(", ""), ("\\)", ""), ("\\[", ""), ("\\]", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        for junk in ["$$", "$", "**", "__", "```", "`"] { s = s.replacingOccurrences(of: junk, with: "") }
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
