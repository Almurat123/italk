import SwiftUI
import UIKit

// MARK: - Design tokens shared by every message component

/// One type scale and rhythm for the whole conversation (answers, reasoning, trace, result cards), modelled on ChatGPT/Codex:
/// body text on the page background, 14 pt between blocks, hairline rules, quiet secondary surfaces for code and data.
enum MarkdownStyle {
    static let lineSpacing: CGFloat = 5
    static let blockSpacing: CGFloat = 14
    static let listSpacing: CGFloat = 6
    static let corner: CGFloat = 14

    static let codeBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1) })
    static let codeBanner = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1) })
    static let inlineCode = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.11) : UIColor(white: 0, alpha: 0.055) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.035) })
    static let hairline = Color(uiColor: .separator)
    static let link = Color.accentColor
}

// MARK: - Block model and parser

/// CommonMark/GFM-style block structure for assistant text: nested lists and task lists, nested quotes, fenced code, GFM tables
/// with alignment, display math ($$…$$, \[…\], \begin{…}), headings (ATX and setext), rules and images. Tolerant of half-streamed
/// input: an unclosed fence or formula renders as "still arriving" until it closes.
indirect enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case code(language: String, text: String, closed: Bool)
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case quote([MarkdownBlock])
    case math(String, closed: Bool)
    case rule
    case image(alt: String, url: URL)
    /// Model-generated interface (```italk-ui fence), rendered natively; see GenerativeUI.swift.
    case generatedUI(String, closed: Bool)

    struct ListItem: Equatable { var checked: Bool?; var blocks: [MarkdownBlock] }
    enum TableAlignment: Equatable { case leading, center, trailing }

    private final class Cached { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Cached> = { let c = NSCache<NSString, Cached>(); c.countLimit = 120; return c }()   // NSCache is thread-safe

    static func parse(_ source: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: source as NSString) { return hit.blocks }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map(expandTabs)
        let blocks = parseLines(lines)
        cache.setObject(Cached(blocks), forKey: source as NSString)
        return blocks
    }

    private static func expandTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") else { return line }
        let tabs = line.prefix { $0 == "\t" }.count
        return String(repeating: " ", count: tabs * 4) + line.dropFirst(tabs)
    }
    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func dedent(_ line: String, _ n: Int) -> String { String(line.dropFirst(min(n, indent(line)))) }

    static func parseLines(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lead = indent(line)

            // Fenced code (``` or ~~~), indented under its fence.
            if lead < 4, let fence = fenceMarker(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
                var body: [String] = []; i += 1
                var closed = false
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence), t.allSatisfy({ $0 == fence.first }) { closed = true; i += 1; break }
                    body.append(dedent(lines[i], lead)); i += 1
                }
                if ["italk-ui", "italkui", "genui", "ui-json"].contains(language.lowercased()) {
                    blocks.append(.generatedUI(body.joined(separator: "\n"), closed: closed)); continue
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n"), closed: closed)); continue
            }
            // Display math.
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") || trimmed.hasPrefix("\\begin{") {
                if let (math, closed, next) = displayMath(lines, from: i) {
                    flush(); blocks.append(.math(math, closed: closed)); i = next; continue
                }
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            // Setext headings.
            if !paragraph.isEmpty, lead < 4, !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.count >= 2 && trimmed.allSatisfy({ $0 == "-" })) {
                let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                paragraph = []
                blocks.append(.heading(trimmed.first == "=" ? 1 : 2, text)); i += 1; continue
            }
            if let heading = heading(trimmed), lead < 4 { flush(); blocks.append(heading); i += 1; continue }
            if isRule(trimmed), lead < 4 { flush(); blocks.append(.rule); i += 1; continue }
            if let image = image(trimmed) { flush(); blocks.append(image); i += 1; continue }
            // GFM table: a row with pipes followed by a delimiter row.
            if trimmed.contains("|"), i + 1 < lines.count, let alignments = tableRule(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []; i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    var row = cells(t)
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(max(header.count, 1)))); i += 1
                }
                let aligned = header.indices.map { $0 < alignments.count ? alignments[$0] : .leading }
                blocks.append(.table(header: header, alignments: aligned, rows: rows)); continue
            }
            // Blockquote (recursive).
            if trimmed.hasPrefix(">"), lead < 4 {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = String(t.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        quoted.append(rest); i += 1
                    } else if !t.isEmpty, let last = quoted.last, !last.trimmingCharacters(in: .whitespaces).isEmpty, listMarker(lines[i]) == nil {
                        quoted.append(t); i += 1          // lazy continuation
                    } else { break }
                }
                blocks.append(.quote(parseLines(quoted))); continue
            }
            // Lists (recursive items).
            if let first = listMarker(line), lead < 4 {
                flush()
                var items: [ListItem] = []
                var current: [String] = [first.text]
                var contentIndent = first.contentIndent
                i += 1
                func finishItem() {
                    var itemLines = current
                    var checked: Bool?
                    if let head = itemLines.first {
                        if head.hasPrefix("[ ] ") || head == "[ ]" { checked = false; itemLines[0] = String(head.dropFirst(min(4, head.count))) }
                        else if head.lowercased().hasPrefix("[x] ") || head.lowercased() == "[x]" { checked = true; itemLines[0] = String(head.dropFirst(min(4, head.count))) }
                    }
                    items.append(ListItem(checked: checked, blocks: parseLines(itemLines)))
                }
                while i < lines.count {
                    let l = lines[i], t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        // A blank line continues the list only if the next content line is indented into the item or is a sibling.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        guard j < lines.count else { i = j; break }
                        if indent(lines[j]) >= contentIndent { current.append(""); i += 1; continue }
                        if let m = listMarker(lines[j]), m.indent == first.indent, m.ordered == first.ordered { i += 1; continue }
                        break
                    }
                    if let m = listMarker(l), m.indent <= first.indent + 1, m.indent < contentIndent {
                        guard m.ordered == first.ordered else { break }
                        finishItem(); current = [m.text]; contentIndent = m.contentIndent; i += 1; continue
                    }
                    if indent(l) >= contentIndent || (listMarker(l) != nil && indent(l) > first.indent) {
                        current.append(dedent(l, contentIndent)); i += 1; continue
                    }
                    if let last = current.last, !last.trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(t) {
                        current.append(t); i += 1; continue          // lazy continuation of the item's paragraph
                    }
                    break
                }
                finishItem()
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items)); continue
            }
            paragraph.append(line); i += 1
        }
        flush()
        return blocks
    }

    private static func startsBlock(_ t: String) -> Bool {
        fenceMarker(t) != nil || heading(t) != nil || t.hasPrefix(">") || t.hasPrefix("$$") || isRule(t)
    }

    private static func fenceMarker(_ t: String) -> String? {
        for f in ["```", "~~~"] where t.hasPrefix(f) { return String(t.prefix { $0 == f.first }) }
        return nil
    }

    private static func displayMath(_ lines: [String], from start: Int) -> (String, Bool, Int)? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let open: String, close: String
        if first.hasPrefix("$$") { open = "$$"; close = "$$" }
        else if first.hasPrefix("\\[") { open = "\\["; close = "\\]" }
        else if first.hasPrefix("\\begin{"), let end = first.range(of: "}") {
            let env = String(first[first.index(first.startIndex, offsetBy: 7)..<end.lowerBound])
            guard ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*", "matrix", "pmatrix", "bmatrix", "cases", "split"].contains(env) else { return nil }
            var body: [String] = [], i = start
            while i < lines.count {
                body.append(lines[i])
                if lines[i].contains("\\end{\(env)}") { return (body.joined(separator: "\n"), true, i + 1) }
                i += 1
            }
            return (body.joined(separator: "\n"), false, i)
        } else { return nil }
        var rest = String(first.dropFirst(open.count))
        if let r = rest.range(of: close) {
            let tail = rest[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty else { return nil }          // "$$a$$ and more" stays a paragraph with inline math
            rest = String(rest[..<r.lowerBound])
            return (rest.trimmingCharacters(in: .whitespacesAndNewlines), true, start + 1)
        }
        var body = [rest], i = start + 1
        while i < lines.count {
            if let r = lines[i].range(of: close) {
                body.append(String(lines[i][..<r.lowerBound]))
                return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), true, i + 1)
            }
            body.append(lines[i]); i += 1
        }
        return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), false, i)
    }

    private static func image(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "]("),
              let url = URL(string: String(line[close.upperBound...].dropLast()).components(separatedBy: " ").first ?? ""),
              url.scheme == "https" else { return nil }
        return .image(alt: String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]), url: url)
    }
    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " || line.count == hashes else { return nil }
        var text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(hashes, text.trimmingCharacters(in: .whitespaces))
    }
    private static func isRule(_ t: String) -> Bool {
        let compact = t.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }
    private static func tableRule(_ line: String) -> [TableAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|-: ".contains($0) }), t.contains("|") || t.contains("---") else { return nil }
        let parts = cells(t)
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains("-") }) else { return nil }
        return parts.map { p in
            let l = p.hasPrefix(":"), r = p.hasSuffix(":")
            return l && r ? .center : r ? .trailing : .leading
        }
    }
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = [], cell = "", inCode = false, previous: Character = " "
        for c in t {
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode, previous != "\\" { out.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
            previous = c
        }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    struct Marker { var indent: Int; var ordered: Bool; var number: Int; var contentIndent: Int; var text: String }
    static func listMarker(_ line: String) -> Marker? {
        let lead = indent(line)
        let t = String(line.dropFirst(lead))
        if let first = t.first, "-*+•".contains(first) {
            let rest = t.dropFirst()
            guard rest.first == " " || rest.isEmpty else { return nil }
            if first != "•", isRule(t) { return nil }
            let spaces = rest.prefix { $0 == " " }.count
            return Marker(indent: lead, ordered: false, number: 1, contentIndent: lead + 1 + max(1, min(spaces, 4)), text: String(rest.dropFirst(spaces)))
        }
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 10 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")", after.dropFirst().first == " " || after.count == 1 else { return nil }
        let rest = after.dropFirst()
        let spaces = rest.prefix { $0 == " " }.count
        return Marker(indent: lead, ordered: true, number: Int(digits) ?? 1, contentIndent: lead + digits.count + 1 + max(1, min(spaces, 4)), text: String(rest.dropFirst(spaces)))
    }

    /// True when the text needs the block renderer; plain prose keeps the native selectable text view.
    static func needsBlocks(_ source: String) -> Bool {
        let signals = ["```", "~~~", "![", "](", "`", "**", "__", "$", "\\(", "\\[", "\\begin{", "\n#", "\n- ", "\n* ", "\n+ ", "\n> ", "|",
                       "\n1. ", "\n1) ", "\n---", "\n==="]
        if signals.contains(where: { source.contains($0) }) { return true }
        return ["#", "- ", "* ", "+ ", "> ", "1. "].contains { source.hasPrefix($0) }
    }
}

// MARK: - Inline rendering

enum MarkdownInline {
    enum Segment: Equatable { case text(String), math(String) }

    /// Splits prose into text and inline math ($…$ or \(…\)). `$5 and $10` stays text: an opening $ must be followed, and a closing
    /// $ preceded, by non-space, and a closing $ must not be followed by a digit. Code spans are never scanned for math.
    static func segments(_ s: String) -> [Segment] {
        let chars = Array(s)
        var out: [Segment] = [], text = "", i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                text.append(contentsOf: chars[i...min(j, chars.count - 1)]); i = j + 1; continue
            }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                if let end = find(chars, "\\)", from: i + 2) {
                    flush(&out, &text); out.append(.math(String(chars[(i + 2)..<end]))); i = end + 2; continue
                }
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] != "$", chars[i + 1] != " ", (i == 0 || chars[i - 1] != "\\") {
                var j = i + 1
                while j < chars.count, chars[j] != "$", chars[j] != "\n" { j += 1 }
                if j < chars.count, chars[j] == "$", chars[j - 1] != " ", j > i + 1, !(j + 1 < chars.count && chars[j + 1].isNumber) {
                    flush(&out, &text); out.append(.math(String(chars[(i + 1)..<j]))); i = j + 1; continue
                }
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] == "$", let end = find(chars, "$$", from: i + 2) {
                flush(&out, &text); out.append(.math(String(chars[(i + 2)..<end]))); i = end + 2; continue
            }
            text.append(c); i += 1
        }
        flush(&out, &text)
        return out
    }
    private static func flush(_ out: inout [Segment], _ text: inout String) { if !text.isEmpty { out.append(.text(text)); text = "" } }
    private static func find(_ chars: [Character], _ needle: String, from: Int) -> Int? {
        let n = Array(needle)
        var i = from
        while i + n.count <= chars.count {
            if Array(chars[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }

    private final class Cached { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Cached> = { let c = NSCache<NSString, Cached>(); c.countLimit = 600; return c }()   // NSCache is thread-safe

    /// Inline Markdown (emphasis, links, code, strikethrough) styled with the shared tokens.
    static func attributed(_ source: String, baseSize: CGFloat) -> AttributedString {
        let key = "\(baseSize)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = makeAttributed(source, baseSize: baseSize)
        cache.setObject(Cached(value), forKey: key)
        return value
    }

    private static func makeAttributed(_ source: String, baseSize: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in result.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    result[run.range].font = .system(size: baseSize * 0.88, design: .monospaced)
                    result[run.range].backgroundColor = MarkdownStyle.inlineCode
                }
                if intent.contains(.stronglyEmphasized) { result[run.range].font = .system(size: baseSize, weight: .semibold) }
            }
            if run.link != nil {
                result[run.range].foregroundColor = MarkdownStyle.link
                result[run.range].underlineStyle = nil
            }
        }
        return result
    }

    /// Prose with inline math typeset as images that sit on the text baseline, so wrapping and selection stay native.
    @MainActor static func text(_ source: String, baseSize: CGFloat, color: UIColor) -> Text {
        let parts = segments(source)
        if parts.count == 1, case .text(let t) = parts[0] { return Text(attributed(t, baseSize: baseSize)) }
        var result = Text("")
        for part in parts {
            switch part {
            case .text(let t): result = result + Text(attributed(t, baseSize: baseSize))
            case .math(let m):
                if let rendered = MathRenderer.render(m, display: false, fontSize: baseSize, color: color) {
                    result = result + Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
                } else {
                    result = result + Text(m).font(.system(size: baseSize * 0.88, design: .monospaced)).foregroundColor(.secondary)
                }
            }
        }
        return result
    }
}

// MARK: - Answer view

/// An assistant answer (or model reasoning) rendered on the page background: one type scale, inline and display math,
/// highlighted code, scrollable tables. `secondary` dims the text for reasoning without changing its size or spacing.
struct MarkdownAnswerView: View {
    let text: String
    var secondary = false
    var streaming = false
    var renderGeneratedUI = true
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: MarkdownStyle.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // Equatable: while an answer streams only the block that is still growing is re-rendered.
                MarkdownBlockView(block: block, depth: 0, secondary: secondary, bodySize: bodySize, colorScheme: colorScheme, isFirst: index == 0, renderGeneratedUI: renderGeneratedUI, streaming: streaming)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View, Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.block == b.block && a.depth == b.depth && a.secondary == b.secondary && a.bodySize == b.bodySize
            && a.colorScheme == b.colorScheme && a.isFirst == b.isFirst && a.renderGeneratedUI == b.renderGeneratedUI && a.streaming == b.streaming
    }
    let block: MarkdownBlock
    let depth: Int
    let secondary: Bool
    let bodySize: CGFloat
    let colorScheme: ColorScheme
    var isFirst = false
    var renderGeneratedUI = true
    var streaming = false

    private var textColor: UIColor {
        (secondary ? UIColor.secondaryLabel : UIColor.label).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }

    var body: some View {
        switch block {
        case .heading(let level, let value):
            let size: CGFloat = level == 1 ? bodySize * 1.35 : level == 2 ? bodySize * 1.2 : level == 3 ? bodySize * 1.08 : bodySize
            MarkdownInline.text(value, baseSize: size, color: textColor)
                .font(.system(size: size, weight: level <= 3 ? .semibold : .semibold))
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : (level <= 2 ? 10 : 4))
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
        case .paragraph(let value):
            MarkdownInline.text(value, baseSize: bodySize, color: textColor)
                .font(.system(size: bodySize)).foregroundStyle(secondary ? .secondary : .primary)
                .lineSpacing(MarkdownStyle.lineSpacing).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: MarkdownStyle.listSpacing + 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                MarkdownBlockView(block: child, depth: depth + 1, secondary: secondary || item.checked == true, bodySize: bodySize,
                                                  colorScheme: colorScheme, isFirst: true, renderGeneratedUI: renderGeneratedUI, streaming: streaming)
                            }
                        }
                    }
                }
            }
        case .code(let language, let code, let closed):
            CodeBlockView(language: language, code: code, closed: closed)
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, bodySize: bodySize, color: textColor)
        case .quote(let blocks):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(block: child, depth: depth + 1, secondary: true, bodySize: bodySize, colorScheme: colorScheme, isFirst: true, renderGeneratedUI: renderGeneratedUI, streaming: streaming)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) { Rectangle().fill(Color(uiColor: .tertiaryLabel)).frame(width: 2) }
        case .math(let latex, let closed):
            MathBlockView(latex: latex, closed: closed)
        case .rule:
            Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5).padding(.vertical, 8)
        case .image(let alt, let url):
            AnswerImage(alt: alt, url: url)
        case .generatedUI(let source, let closed):
            if renderGeneratedUI { GenUIBlockView(source: source, closed: closed || !streaming) }
            else { CodeBlockView(language: "italk-ui", code: source, closed: closed) }
        }
    }

    @ViewBuilder private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: bodySize * 0.9)).foregroundStyle(checked ? Color.accentColor : .secondary)
                .frame(width: 22, alignment: .leading)
                .accessibilityLabel(checked ? "已完成" : "未完成")
        } else if ordered {
            Text("\(number).").font(.system(size: bodySize).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : depth == 1 ? "◦" : "▪").font(.system(size: bodySize, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
        }
    }
}

// MARK: - Code

struct CodeBlockView: View {
    let language: String
    let code: String
    var closed = true
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let label = CodeHighlighter.language(language).label
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label.isEmpty ? "代码" : label).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !closed { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    UIPasteboard.general.string = code; copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("code.copy")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(MarkdownStyle.codeBanner)
            ScrollView(.horizontal) {
                CodeTextView(code: code, language: language, dark: colorScheme == .dark)
                    .padding(.horizontal, 12).padding(.vertical, 11)
            }
            .scrollIndicators(.visible).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(MarkdownStyle.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("markdown.code")
    }
}

// MARK: - Tables

struct TableBlockView: View {
    let header: [String]
    let alignments: [MarkdownBlock.TableAlignment]
    let rows: [[String]]
    let bodySize: CGFloat
    let color: UIColor

    private func alignment(_ column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var body: some View {
        let size = bodySize * 0.92
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
                        MarkdownInline.text(cell, baseSize: size, color: color).font(.system(size: size, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(minWidth: 64, maxWidth: 260, maxHeight: .infinity, alignment: alignment(c))
                    }
                }
                .background(MarkdownStyle.surface)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            MarkdownInline.text(cell, baseSize: size, color: color).font(.system(size: size))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .frame(minWidth: 64, maxWidth: 260, maxHeight: .infinity, alignment: alignment(c))
                        }
                    }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MarkdownStyle.hairline, lineWidth: 0.5) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.vertical, 1)
        }
        .scrollIndicators(.visible).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .textSelection(.enabled)
        .accessibilityIdentifier("markdown.table")
    }
}

// MARK: - Images

struct AnswerImage: View {
    let alt: String
    let url: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure:
                    Label(alt.isEmpty ? "图片无法加载" : "图片无法加载：\(alt)", systemImage: "photo")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 72)
                        .background(MarkdownStyle.surface)
                default: Rectangle().fill(MarkdownStyle.surface).frame(height: 180).overlay { ProgressView() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous))
            if !alt.isEmpty { Text(alt).font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine).accessibilityLabel(alt.isEmpty ? "图片" : alt)
    }
}

/// Copy / read-aloud / retry row under a finished answer, as in ChatGPT.
struct AnswerActions: View {
    let text: String
    let canRead: Bool
    let read: (String) -> Void
    var retry: (() -> Void)?
    @State private var copied = false
    var body: some View {
        HStack(spacing: 4) {
            action(copied ? "checkmark" : "doc.on.doc", label: "复制回答") {
                UIPasteboard.general.string = text; copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            action("speaker.wave.2", label: "朗读回答") { read(text) }.disabled(!canRead)
            if let retry { action("arrow.clockwise", label: "重新回答", retry) }
        }
        .font(.system(size: 15)).foregroundStyle(.secondary).buttonStyle(.plain)
        .padding(.leading, -8)
    }
    private func action(_ symbol: String, label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).frame(width: 34, height: 30).contentShape(Rectangle()) }.accessibilityLabel(label)
    }
}
