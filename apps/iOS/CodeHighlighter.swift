import SwiftUI
import UIKit

/// Lightweight lexical highlighting for fenced code: comments, strings, numbers, keywords, types, calls and attributes, with
/// Xcode-like colours that adapt to light and dark. A tokenizer, not a parser: it never fails, and unknown languages get the
/// generic C-family rules.
enum CodeHighlighter {
    enum Token { case plain, keyword, string, comment, number, type, call, attribute, punctuation }

    struct Language {
        var keywords: Set<String>
        var lineComment: [String]
        var blockComment: (String, String)?
        var stringQuotes: Set<Character>
        var tripleQuotes = false
        var attributePrefix: Character?
        var caseInsensitive = false
    }

    static func language(_ name: String) -> (label: String, rules: Language) {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        let cFamily = Language(keywords: [], lineComment: ["//"], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'"])
        switch n {
        case "swift":
            return ("Swift", Language(keywords: ["let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case",
                "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "init", "deinit", "self", "Self", "super",
                "true", "false", "nil", "try", "catch", "throw", "throws", "rethrows", "async", "await", "public", "private", "fileprivate", "internal",
                "open", "static", "final", "override", "mutating", "lazy", "weak", "unowned", "inout", "some", "any", "where", "as", "is", "do", "defer",
                "typealias", "associatedtype", "subscript", "operator", "actor", "nonisolated", "isolated", "consuming", "borrowing", "sending", "macro"],
                lineComment: ["//"], blockComment: ("/*", "*/"), stringQuotes: ["\""], tripleQuotes: true, attributePrefix: "@"))
        case "python", "py":
            return ("Python", Language(keywords: ["def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "return", "yield",
                "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "global", "nonlocal",
                "None", "True", "False", "async", "await", "del", "assert", "match", "case", "self"],
                lineComment: ["#"], blockComment: nil, stringQuotes: ["\"", "'"], tripleQuotes: true, attributePrefix: "@"))
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "mjs":
            return (n.hasPrefix("t") ? "TypeScript" : "JavaScript", Language(keywords: ["const", "let", "var", "function", "return", "if", "else", "for",
                "while", "do", "switch", "case", "default", "break", "continue", "new", "class", "extends", "super", "this", "import", "export", "from",
                "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false",
                "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "void", "yield", "delete"],
                lineComment: ["//"], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'", "`"], attributePrefix: "@"))
        case "java", "kotlin", "kt", "c", "cpp", "c++", "h", "hpp", "objc", "objective-c", "csharp", "cs", "go", "rust", "rs", "dart", "scala", "php":
            var rules = cFamily
            rules.keywords = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "class", "struct", "enum",
                "interface", "public", "private", "protected", "static", "final", "const", "void", "int", "long", "float", "double", "char", "bool",
                "boolean", "true", "false", "null", "nil", "new", "this", "self", "import", "package", "using", "namespace", "try", "catch", "throw",
                "throws", "func", "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "val", "var", "fun", "object", "when", "is", "in",
                "go", "defer", "chan", "select", "type", "map", "range", "auto", "virtual", "override", "template", "typename", "unsigned", "include",
                "async", "await", "where", "as", "crate", "extern", "unsafe", "loop", "sizeof", "goto", "echo", "function"]
            rules.attributePrefix = n == "rust" || n == "rs" ? "#" : "@"
            let label = ["kt": "Kotlin", "cpp": "C++", "c++": "C++", "objc": "Objective-C", "cs": "C#", "csharp": "C#", "rs": "Rust", "h": "C", "hpp": "C++"][n] ?? n.capitalized
            return (label, rules)
        case "bash", "sh", "zsh", "shell", "console", "fish":
            return ("Shell", Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                "return", "export", "local", "echo", "cd", "sudo", "set", "unset", "source", "exit"],
                lineComment: ["#"], blockComment: nil, stringQuotes: ["\"", "'"]))
        case "sql":
            return ("SQL", Language(keywords: ["select", "from", "where", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
                "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "drop", "alter", "and", "or", "not", "null", "as",
                "distinct", "limit", "offset", "union", "all", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references",
                "count", "sum", "avg", "min", "max", "is", "in", "like", "between", "exists", "with"],
                lineComment: ["--"], blockComment: ("/*", "*/"), stringQuotes: ["'", "\""], caseInsensitive: true))
        case "json", "jsonc":
            return ("JSON", Language(keywords: ["true", "false", "null"], lineComment: [], blockComment: nil, stringQuotes: ["\""]))
        case "yaml", "yml", "toml", "ini":
            return (n == "toml" ? "TOML" : n == "ini" ? "INI" : "YAML", Language(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                lineComment: ["#"], blockComment: nil, stringQuotes: ["\"", "'"]))
        case "html", "xml", "svg", "vue":
            return (n.uppercased(), Language(keywords: [], lineComment: [], blockComment: ("<!--", "-->"), stringQuotes: ["\"", "'"]))
        case "css", "scss", "less":
            return (n.uppercased(), Language(keywords: ["important", "media", "import", "from", "to"], lineComment: n == "css" ? [] : ["//"],
                blockComment: ("/*", "*/"), stringQuotes: ["\"", "'"], attributePrefix: "@"))
        case "ruby", "rb":
            return ("Ruby", Language(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
                "return", "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false", "self", "require", "attr_accessor", "puts"],
                lineComment: ["#"], blockComment: nil, stringQuotes: ["\"", "'"]))
        case "", "text", "txt", "plaintext", "output", "log":
            return (n.isEmpty ? "" : "Text", Language(keywords: [], lineComment: [], blockComment: nil, stringQuotes: []))
        default:
            var rules = cFamily
            rules.keywords = ["if", "else", "for", "while", "return", "function", "def", "class", "true", "false", "null", "nil", "let", "var", "const"]
            return (name, rules)
        }
    }

    static func color(_ token: Token, dark: Bool) -> UIColor {
        func hex(_ v: UInt32) -> UIColor { UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        switch token {
        case .plain, .punctuation: return .label
        case .keyword: return dark ? hex(0xFF7AB2) : hex(0xAD3DA4)
        case .string: return dark ? hex(0xFF8170) : hex(0xC41A16)
        case .comment: return dark ? hex(0x7F8C98) : hex(0x5D6C79)
        case .number: return dark ? hex(0xD9C97C) : hex(0x1C00CF)
        case .type: return dark ? hex(0xDABAFF) : hex(0x3900A0)
        case .call: return dark ? hex(0x67B7A4) : hex(0x326D74)
        case .attribute: return dark ? hex(0xCC9768) : hex(0x947100)
        }
    }

    /// Highlighted text for a code block. Large inputs (very long logs) fall back to plain text to keep scrolling smooth.
    static func highlight(_ code: String, language: String, dark: Bool, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: UIColor.label])
        guard code.utf16.count < 60_000 else { return result }
        let rules = Self.language(language).rules
        let chars = Array(code.utf16)
        let ns = code as NSString
        var i = 0
        func paint(_ start: Int, _ end: Int, _ token: Token) {
            guard end > start else { return }
            result.addAttribute(.foregroundColor, value: color(token, dark: dark), range: NSRange(location: start, length: end - start))
        }
        func hasPrefix(_ p: String, at k: Int) -> Bool {
            let u = Array(p.utf16)
            guard k + u.count <= chars.count else { return false }
            for (o, c) in u.enumerated() where chars[k + o] != c { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        let isMarkup = ["html", "xml", "svg", "vue"].contains(language.lowercased())
        let isJSON = ["json", "jsonc"].contains(language.lowercased())
        while i < chars.count {
            let c = chars[i]
            // comments
            if let line = rules.lineComment.first(where: { hasPrefix($0, at: i) }) {
                let start = i
                _ = line
                while i < chars.count, chars[i] != 10 { i += 1 }
                paint(start, i, .comment); continue
            }
            if let block = rules.blockComment, hasPrefix(block.0, at: i) {
                let start = i
                i += block.0.utf16.count
                while i < chars.count, !hasPrefix(block.1, at: i) { i += 1 }
                i = min(chars.count, i + block.1.utf16.count)
                paint(start, i, .comment); continue
            }
            // markup tags
            if isMarkup, c == 60 /* < */ {
                let start = i; i += 1
                if i < chars.count, chars[i] == 47 { i += 1 }
                while i < chars.count, isIdent(chars[i]) || chars[i] == 45 || chars[i] == 58 { i += 1 }
                paint(start, i, .keyword); continue
            }
            // strings
            if let scalar = UnicodeScalar(c), rules.stringQuotes.contains(Character(scalar)) {
                let start = i
                let triple = rules.tripleQuotes && i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                i += triple ? 3 : 1
                while i < chars.count {
                    if chars[i] == 92 { i += 2; continue }
                    if triple { if i + 2 < chars.count, chars[i] == c, chars[i + 1] == c, chars[i + 2] == c { i += 3; break } }
                    else if chars[i] == c { i += 1; break }
                    else if chars[i] == 10 && c != 96 { break }
                    i += 1
                }
                i = min(i, chars.count)
                // JSON keys read as properties, not strings.
                var j = i
                while j < chars.count, chars[j] == 32 { j += 1 }
                paint(start, i, isJSON && j < chars.count && chars[j] == 58 ? .call : .string)
                continue
            }
            // numbers
            if c >= 48 && c <= 57, i == 0 || !isIdent(chars[i - 1]) {
                let start = i
                while i < chars.count, isIdent(chars[i]) || chars[i] == 46 { i += 1 }
                paint(start, i, .number); continue
            }
            // attributes / decorators / preprocessor
            if let prefix = rules.attributePrefix, let scalar = UnicodeScalar(c), Character(scalar) == prefix, i + 1 < chars.count, isIdentStart(chars[i + 1]) {
                let start = i; i += 1
                while i < chars.count, isIdent(chars[i]) { i += 1 }
                paint(start, i, .attribute); continue
            }
            // identifiers
            if isIdentStart(c) {
                let start = i
                while i < chars.count, isIdent(chars[i]) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                let key = rules.caseInsensitive ? word.lowercased() : word
                if rules.keywords.contains(key) { paint(start, i, .keyword) }
                else if i < chars.count, chars[i] == 40 /* ( */ { paint(start, i, .call) }
                else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), !isMarkup { paint(start, i, .type) }
                continue
            }
            i += 1
        }
        return result
    }
}

/// A code block's text: real text selection (drag handles, copy), no wrapping, scrolls horizontally inside the block.
struct CodeTextView: UIViewRepresentable {
    let code: String
    let language: String
    let dark: Bool

    static var font: UIFont { UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13.5, weight: .regular)) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byClipping
        view.textContainer.widthTracksTextView = false
        view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.dataDetectorTypes = []
        view.accessibilityIdentifier = "code.text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let key = "\(dark)|\(language)|\(code.hashValue)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        let text = NSMutableAttributedString(attributedString: CodeHighlighter.highlight(code, language: language, dark: dark, font: Self.font))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        view.attributedText = text
        context.coordinator.size = Self.measure(text)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var key = ""; var size = CGSize.zero }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if context.coordinator.size == .zero, let text = uiView.attributedText { context.coordinator.size = Self.measure(text) }
        return context.coordinator.size
    }

    static func measure(_ text: NSAttributedString) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(rect.width) + 2, height: ceil(rect.height) + 1)
    }
}
