import SwiftUI
import UIKit
import CoreText

// A small native TeX-style math typesetter: LaTeX subset → box layout (TeX's ascent/descent model, math axis, script
// styles, inter-atom spacing) → drawn with Core Text into a cached image. Covers what assistants actually emit: fractions,
// binomials, roots, sub/superscripts, Greek, operators and relations, big operators with limits, integrals, \left…\right
// delimiters, matrices / cases / aligned rows, accents, \text and font styles. Anything it does not understand fails
// as a whole, and the caller shows the source in code style instead of a half-rendered formula.

// MARK: - Tree

indirect enum MathNode {
    case atom(String, MathKind)
    case row([MathNode])
    case fraction(MathNode, MathNode, rule: Bool)
    case scripts(MathNode, sup: MathNode?, sub: MathNode?)
    case radical(MathNode, index: MathNode?)
    case largeOp(String, sup: MathNode?, sub: MathNode?, integral: Bool, limits: Bool)
    case fenced(String, MathNode, String)
    case matrix([[MathNode]], left: String, right: String, align: [Character], spread: CGFloat)
    case accent(MathNode, MathAccent)
    case space(CGFloat)
    case styled(MathNode, MathFontStyle)
}

enum MathKind { case ordinary, variable, binary, relation, open, close, punctuation, function, op }
enum MathAccent { case hat, bar, vec, dot, ddot, tilde, overline, underline }
enum MathFontStyle { case roman, bold, text, blackboard, calligraphic, italic }

struct MathParseError: Error {}

// MARK: - Tokens

private enum MathToken: Equatable {
    case command(String), char(Character), open, close, sup, sub, amp, newline, raw(String), begin(String), end(String)
}

private struct MathLexer {
    static let rawCommands: Set<String> = ["text", "textrm", "textbf", "textit", "mbox", "mathrm_raw", "operatorname", "textsf", "texttt"]

    static func tokens(_ source: String) throws -> [MathToken] {
        let s = Array(source)
        var i = 0, out: [MathToken] = []
        func readGroupRaw() throws -> String {
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count, s[i] == "{" else { throw MathParseError() }
            i += 1
            var depth = 1, text = ""
            while i < s.count {
                if s[i] == "{" { depth += 1 } else if s[i] == "}" { depth -= 1; if depth == 0 { i += 1; return text } }
                text.append(s[i]); i += 1
            }
            throw MathParseError()
        }
        while i < s.count {
            let c = s[i]
            switch c {
            case "\\":
                i += 1
                guard i < s.count else { throw MathParseError() }
                if s[i].isLetter {
                    var name = ""
                    while i < s.count, s[i].isLetter { name.append(s[i]); i += 1 }
                    if name == "begin" || name == "end" {
                        let env = try readGroupRaw().trimmingCharacters(in: .whitespaces)
                        out.append(name == "begin" ? .begin(env.replacingOccurrences(of: "*", with: "")) : .end(env.replacingOccurrences(of: "*", with: "")))
                    } else if rawCommands.contains(name) {
                        out.append(.command(name)); out.append(.raw(try readGroupRaw()))
                    } else { out.append(.command(name)) }
                } else if s[i] == "\\" { out.append(.newline); i += 1 }
                else { out.append(.command(String(s[i]))); i += 1 }
            case "{": out.append(.open); i += 1
            case "}": out.append(.close); i += 1
            case "^": out.append(.sup); i += 1
            case "_": out.append(.sub); i += 1
            case "&": out.append(.amp); i += 1
            case " ", "\n", "\t", "\r": i += 1
            case "~": out.append(.command(" ")); i += 1
            default: out.append(.char(c)); i += 1
            }
        }
        return out
    }
}

// MARK: - Parser

private struct MathParser {
    var tokens: [MathToken]
    var i = 0

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
    ]
    static let symbols: [String: (String, MathKind)] = [
        // binary
        "pm": ("±", .binary), "mp": ("∓", .binary), "times": ("×", .binary), "div": ("÷", .binary), "cdot": ("⋅", .binary),
        "ast": ("∗", .binary), "star": ("⋆", .binary), "circ": ("∘", .binary), "bullet": ("∙", .binary), "oplus": ("⊕", .binary),
        "ominus": ("⊖", .binary), "otimes": ("⊗", .binary), "odot": ("⊙", .binary), "cup": ("∪", .binary), "cap": ("∩", .binary),
        "setminus": ("∖", .binary), "wedge": ("∧", .binary), "land": ("∧", .binary), "vee": ("∨", .binary), "lor": ("∨", .binary),
        // relations
        "leq": ("≤", .relation), "le": ("≤", .relation), "geq": ("≥", .relation), "ge": ("≥", .relation), "neq": ("≠", .relation),
        "ne": ("≠", .relation), "approx": ("≈", .relation), "equiv": ("≡", .relation), "sim": ("∼", .relation), "simeq": ("≃", .relation),
        "cong": ("≅", .relation), "propto": ("∝", .relation), "ll": ("≪", .relation), "gg": ("≫", .relation), "in": ("∈", .relation),
        "notin": ("∉", .relation), "ni": ("∋", .relation), "subset": ("⊂", .relation), "subseteq": ("⊆", .relation), "supset": ("⊃", .relation),
        "supseteq": ("⊇", .relation), "to": ("→", .relation), "rightarrow": ("→", .relation), "leftarrow": ("←", .relation),
        "gets": ("←", .relation), "leftrightarrow": ("↔", .relation), "Rightarrow": ("⇒", .relation), "Leftarrow": ("⇐", .relation),
        "Leftrightarrow": ("⇔", .relation), "implies": ("⟹", .relation), "iff": ("⟺", .relation), "mapsto": ("↦", .relation),
        "longrightarrow": ("⟶", .relation), "uparrow": ("↑", .relation), "downarrow": ("↓", .relation), "perp": ("⊥", .relation),
        "parallel": ("∥", .relation), "mid": ("∣", .relation), "prec": ("≺", .relation), "succ": ("≻", .relation), "models": ("⊨", .relation),
        "vdash": ("⊢", .relation), "coloneqq": ("≔", .relation), "doteq": ("≐", .relation),
        // ordinary
        "infty": ("∞", .ordinary), "partial": ("∂", .ordinary), "nabla": ("∇", .ordinary), "forall": ("∀", .ordinary), "exists": ("∃", .ordinary),
        "nexists": ("∄", .ordinary), "emptyset": ("∅", .ordinary), "varnothing": ("∅", .ordinary), "hbar": ("ℏ", .ordinary), "ell": ("ℓ", .ordinary),
        "Re": ("ℜ", .ordinary), "Im": ("ℑ", .ordinary), "aleph": ("ℵ", .ordinary), "angle": ("∠", .ordinary), "triangle": ("△", .ordinary),
        "neg": ("¬", .ordinary), "lnot": ("¬", .ordinary), "prime": ("′", .ordinary), "degree": ("°", .ordinary), "dagger": ("†", .ordinary),
        "ldots": ("…", .ordinary), "dots": ("…", .ordinary), "cdots": ("⋯", .ordinary), "vdots": ("⋮", .ordinary), "ddots": ("⋱", .ordinary),
        "top": ("⊤", .ordinary), "bot": ("⊥", .ordinary), "checkmark": ("✓", .ordinary), "%": ("%", .ordinary), "$": ("$", .ordinary),
        "#": ("#", .ordinary), "&": ("&", .ordinary), "_": ("_", .ordinary), "|": ("‖", .ordinary),
        // delimiters
        "{": ("{", .open), "}": ("}", .close), "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "lvert": ("|", .open), "rvert": ("|", .close), "lVert": ("‖", .open), "rVert": ("‖", .close),
        // punctuation
        "colon": (":", .punctuation),
    ]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp", "deg", "dim", "ker", "arg", "gcd", "Pr", "hom", "mod", "bmod"]
    static let limitOps: [String: String] = ["lim": "lim", "max": "max", "min": "min", "sup": "sup", "inf": "inf", "limsup": "lim sup",
        "liminf": "lim inf", "det": "det", "argmax": "arg max", "argmin": "arg min"]
    static let bigOps: [String: (String, Bool)] = ["sum": ("∑", false), "prod": ("∏", false), "coprod": ("∐", false), "bigcup": ("⋃", false),
        "bigcap": ("⋂", false), "bigoplus": ("⨁", false), "bigotimes": ("⨂", false), "bigvee": ("⋁", false), "bigwedge": ("⋀", false),
        "int": ("∫", true), "iint": ("∬", true), "iiint": ("∭", true), "oint": ("∮", true)]
    static let spaces: [String: CGFloat] = [",": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, ";": 5.0 / 18, "!": -3.0 / 18, " ": 1.0 / 3,
        "quad": 1, "qquad": 2, "enspace": 0.5, "thinspace": 3.0 / 18, "medspace": 4.0 / 18, "thickspace": 5.0 / 18]
    static let ignored: Set<String> = ["displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "nolimits", "limits", "left.", "big",
        "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "nonumber", "notag", "mathstrut", "strut", "tag"]

    init(_ source: String) throws { tokens = try MathLexer.tokens(source) }

    var peek: MathToken? { i < tokens.count ? tokens[i] : nil }
    mutating func next() -> MathToken? { defer { i += 1 }; return peek }

    mutating func parseDocument() throws -> MathNode {
        // Top-level rows separated by \\ become an aligned block (models often emit them without an environment).
        if tokens.contains(.newline) || tokens.contains(.amp) {
            if case .begin = tokens.first {} else {
                let rows = try parseRows(until: nil)
                guard i >= tokens.count else { throw MathParseError() }
                return .matrix(rows, left: ".", right: ".", align: ["r", "l"], spread: 0)
            }
        }
        let row = try parseRow { _ in false }
        guard i >= tokens.count else { throw MathParseError() }
        return .row(row)
    }

    mutating func parseRows(until env: String?) throws -> [[MathNode]] {
        var rows: [[MathNode]] = [], cells: [MathNode] = []
        while true {
            let cell = try parseRow { t in
                if case .end = t { return true }
                return t == .amp || t == .newline
            }
            cells.append(.row(cell))
            switch peek {
            case .amp: i += 1
            case .newline: i += 1; rows.append(cells); cells = []
            case .end(let name):
                guard name == env else { throw MathParseError() }
                i += 1; rows.append(cells); return rows.filter { !($0.count == 1 && Self.isEmpty($0[0])) || rows.count == 1 }
            case nil:
                guard env == nil else { throw MathParseError() }
                rows.append(cells); return rows.filter { !($0.count == 1 && Self.isEmpty($0[0])) || rows.count == 1 }
            default: throw MathParseError()
            }
        }
    }

    static func isEmpty(_ node: MathNode) -> Bool { if case .row(let r) = node { return r.isEmpty } else { return false } }

    mutating func parseRow(stop: (MathToken) -> Bool) throws -> [MathNode] {
        var nodes: [MathNode] = []
        while let t = peek, !stop(t) {
            switch t {
            case .sup, .sub:
                i += 1
                let arg = try parseArgument()
                let base = nodes.popLast() ?? .row([])
                nodes.append(try Self.attach(arg, to: base, superscript: t == .sup))
            case .close: return nodes
            case .newline, .amp, .end: throw MathParseError()
            default:
                if let node = try parseAtom() { nodes.append(node) }
            }
        }
        return nodes
    }

    static func attach(_ script: MathNode, to base: MathNode, superscript: Bool) throws -> MathNode {
        switch base {
        case .largeOp(let s, let sup, let sub, let integral, let limits):
            if superscript { guard sup == nil else { throw MathParseError() }; return .largeOp(s, sup: script, sub: sub, integral: integral, limits: limits) }
            guard sub == nil else { throw MathParseError() }; return .largeOp(s, sup: sup, sub: script, integral: integral, limits: limits)
        case .scripts(let b, let sup, let sub):
            if superscript, sup == nil { return .scripts(b, sup: script, sub: sub) }
            if !superscript, sub == nil { return .scripts(b, sup: sup, sub: script) }
            throw MathParseError()
        default:
            return superscript ? .scripts(base, sup: script, sub: nil) : .scripts(base, sup: nil, sub: script)
        }
    }

    mutating func parseArgument() throws -> MathNode {
        guard let t = peek else { throw MathParseError() }
        switch t {
        case .open:
            i += 1
            let row = try parseRow { $0 == .close }
            guard next() == .close else { throw MathParseError() }
            return .row(row)
        case .char(let c) where c.isNumber:
            i += 1; return .atom(String(c), .ordinary)
        default:
            guard let node = try parseAtom() else { throw MathParseError() }
            return node
        }
    }

    mutating func parseGroupNode() throws -> MathNode { try parseArgument() }

    mutating func parseDelimiter() throws -> String {
        guard let t = next() else { throw MathParseError() }
        switch t {
        case .char(let c) where "()[]|./<>".contains(c): return c == "<" ? "⟨" : c == ">" ? "⟩" : String(c)
        case .command(let name):
            switch name {
            case "{", "lbrace": return "{"
            case "}", "rbrace": return "}"
            case "|", "Vert", "lVert", "rVert": return "‖"
            case "vert", "lvert", "rvert": return "|"
            case "langle": return "⟨"
            case "rangle": return "⟩"
            case "lfloor": return "⌊"
            case "rfloor": return "⌋"
            case "lceil": return "⌈"
            case "rceil": return "⌉"
            default: throw MathParseError()
            }
        default: throw MathParseError()
        }
    }

    mutating func parseAtom() throws -> MathNode? {
        guard let t = next() else { return nil }
        switch t {
        case .open:
            let row = try parseRow { $0 == .close }
            guard next() == .close else { throw MathParseError() }
            return .row(row)
        case .char(let c):
            if c.isNumber || c == "." {
                var digits = String(c)
                while case .char(let d)? = peek, d.isNumber || (d == "." && digits.last?.isNumber == true) { digits.append(d); i += 1 }
                return .atom(digits, .ordinary)
            }
            if c.isLetter { return .atom(String(c), c.isASCII ? .variable : .ordinary) }
            switch c {
            case "+": return .atom("+", .binary)
            case "-": return .atom("−", .binary)
            case "*": return .atom("∗", .binary)
            case "/": return .atom("/", .ordinary)
            case "=": return .atom("=", .relation)
            case "<": return .atom("<", .relation)
            case ">": return .atom(">", .relation)
            case ":": return .atom(":", .relation)
            case "(", "[": return .atom(String(c), .open)
            case ")", "]": return .atom(String(c), .close)
            case ",", ";": return .atom(String(c), .punctuation)
            case "'": return .scripts(.row([]), sup: .atom("′", .ordinary), sub: nil)
            case "|": return .atom("|", .ordinary)
            case "!", "?": return .atom(String(c), .close)
            default: return .atom(String(c), .ordinary)
            }
        case .command(let name): return try command(name)
        case .begin(let env): return try environment(env)
        case .raw: throw MathParseError()
        default: throw MathParseError()
        }
    }

    mutating func command(_ name: String) throws -> MathNode? {
        if let g = Self.greek[name] { return .atom(g, name.first!.isLowercase ? .variable : .ordinary) }
        if let s = Self.symbols[name] { return .atom(s.0, s.1) }
        if let w = Self.spaces[name] { return .space(w) }
        if Self.functions.contains(name) { return .atom(name == "bmod" ? "mod" : name, .function) }
        if let l = Self.limitOps[name] { return .largeOp(l, sup: nil, sub: nil, integral: false, limits: true) }
        if let op = Self.bigOps[name] { return .largeOp(op.0, sup: nil, sub: nil, integral: op.1, limits: !op.1) }
        if Self.ignored.contains(name) { return .row([]) }
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let a = try parseArgument(), b = try parseArgument()
            return .fraction(a, b, rule: true)
        case "binom", "dbinom", "tbinom", "choose":
            let a = try parseArgument(), b = try parseArgument()
            return .fenced("(", .fraction(a, b, rule: false), ")")
        case "sqrt":
            var index: MathNode?
            if peek == .char("[") {
                i += 1
                let row = try parseRow { $0 == .char("]") }
                guard next() == .char("]") else { throw MathParseError() }
                index = .row(row)
            }
            return .radical(try parseArgument(), index: index)
        case "left":
            let l = try parseDelimiter()
            let row = try parseRow { $0 == .command("right") }
            guard next() == .command("right") else { throw MathParseError() }
            let r = try parseDelimiter()
            return .fenced(l, .row(row), r)
        case "right": throw MathParseError()
        case "middle": return .atom(try parseDelimiter(), .relation)
        case "hat", "widehat": return .accent(try parseArgument(), .hat)
        case "bar": return .accent(try parseArgument(), .bar)
        case "overline": return .accent(try parseArgument(), .overline)
        case "underline", "underbrace": return .accent(try parseArgument(), .underline)
        case "overbrace": return .accent(try parseArgument(), .overline)
        case "vec", "overrightarrow": return .accent(try parseArgument(), .vec)
        case "dot": return .accent(try parseArgument(), .dot)
        case "ddot": return .accent(try parseArgument(), .ddot)
        case "tilde", "widetilde": return .accent(try parseArgument(), .tilde)
        case "mathrm", "mathsf", "mathtt", "rm": return .styled(try parseArgument(), .roman)
        case "mathbf", "boldsymbol", "bm", "bf": return .styled(try parseArgument(), .bold)
        case "mathit": return .styled(try parseArgument(), .italic)
        case "mathbb": return .styled(try parseArgument(), .blackboard)
        case "mathcal", "mathscr": return .styled(try parseArgument(), .calligraphic)
        case "mathop", "mathrel", "mathbin", "mathord", "mathopen", "mathclose", "mathpunct", "displaylimits": return try parseArgument()
        case "text", "textrm", "textbf", "textit", "mbox", "textsf", "texttt":
            guard case .raw(let raw)? = next() else { throw MathParseError() }
            return .styled(.atom(raw, .ordinary), name == "textbf" ? .bold : .text)
        case "operatorname":
            guard case .raw(let raw)? = next() else { throw MathParseError() }
            return .atom(raw, .function)
        case "color":
            _ = try parseArgument(); return .row([])
        case "textcolor":
            _ = try parseArgument(); return try parseArgument()
        case "not":
            guard let n = try parseAtom() else { throw MathParseError() }
            if case .atom(let s, let k) = n { return .atom(s + "\u{338}", k) }
            return n
        default: throw MathParseError()
        }
    }

    mutating func environment(_ env: String) throws -> MathNode {
        switch env {
        case "matrix", "smallmatrix": return .matrix(try parseRows(until: env), left: ".", right: ".", align: ["c"], spread: 1)
        case "pmatrix": return .matrix(try parseRows(until: env), left: "(", right: ")", align: ["c"], spread: 1)
        case "bmatrix": return .matrix(try parseRows(until: env), left: "[", right: "]", align: ["c"], spread: 1)
        case "Bmatrix": return .matrix(try parseRows(until: env), left: "{", right: "}", align: ["c"], spread: 1)
        case "vmatrix": return .matrix(try parseRows(until: env), left: "|", right: "|", align: ["c"], spread: 1)
        case "Vmatrix": return .matrix(try parseRows(until: env), left: "‖", right: "‖", align: ["c"], spread: 1)
        case "cases", "dcases": return .matrix(try parseRows(until: env), left: "{", right: ".", align: ["l", "l"], spread: 1)
        case "aligned", "align", "split", "gathered", "gather", "equation", "alignat", "eqnarray":
            return .matrix(try parseRows(until: env), left: ".", right: ".", align: env.hasPrefix("gather") || env == "equation" ? ["c"] : ["r", "l"], spread: 0)
        case "array":
            var spec: [Character] = []
            if peek == .open {
                i += 1
                while let t = next(), t != .close { if case .char(let c) = t, "lcr".contains(c) { spec.append(c) } }
            }
            return .matrix(try parseRows(until: env), left: ".", right: ".", align: spec.isEmpty ? ["c"] : spec, spread: 1)
        default: throw MathParseError()
        }
    }
}

// MARK: - Layout

/// A laid-out box: width, height above the baseline, depth below it, and how to draw itself with its baseline origin at (x, y)
/// in UIKit (y-down) coordinates.
final class MathBox {
    var width: CGFloat, ascent: CGFloat, descent: CGFloat
    var kind: MathKind
    let draw: (CGContext, CGFloat, CGFloat) -> Void
    init(width: CGFloat, ascent: CGFloat, descent: CGFloat, kind: MathKind = .ordinary, draw: @escaping (CGContext, CGFloat, CGFloat) -> Void) {
        self.width = width; self.ascent = ascent; self.descent = descent; self.kind = kind; self.draw = draw
    }
    static func empty(_ width: CGFloat = 0) -> MathBox { MathBox(width: width, ascent: 0, descent: 0) { _, _, _ in } }
}

struct MathLayout {
    let base: CGFloat          // body font size
    let color: UIColor
    var display: Bool

    /// 0 = display/text, 1 = script, 2 = scriptscript
    struct Style { var level: Int; var cramped = false }

    func size(_ s: Style) -> CGFloat { s.level == 0 ? base : s.level == 1 ? max(8, base * 0.71) : max(7, base * 0.52) }
    func em(_ s: Style) -> CGFloat { size(s) }
    func axis(_ s: Style) -> CGFloat { size(s) * 0.25 }
    func rule(_ s: Style) -> CGFloat { max(0.6, size(s) * 0.055) }

    func font(_ s: Style, italic: Bool, bold: Bool = false, scale: CGFloat = 1) -> CTFont {
        var descriptor = UIFont.systemFont(ofSize: size(s) * scale, weight: bold ? .semibold : .regular).fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        if italic, let d = descriptor.withSymbolicTraits(.traitItalic) { descriptor = d }
        return UIFont(descriptor: descriptor, size: size(s) * scale) as CTFont
    }

    func glyphs(_ text: String, _ s: Style, italic: Bool, bold: Bool = false, scale: CGFloat = 1, kind: MathKind = .ordinary) -> MathBox {
        let f = font(s, italic: italic, bold: bold, scale: scale)
        let attributed = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let xHeight = CTFontGetXHeight(f)
        let ascent = max(bounds.maxY, xHeight), descent = max(-bounds.minY, 0)
        let slant: CGFloat = italic ? size(s) * 0.04 : 0
        return MathBox(width: width + slant, ascent: ascent, descent: descent, kind: kind) { ctx, x, y in
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x, y: y); ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: rows and spacing

    func hbox(_ boxes: [MathBox], _ s: Style) -> MathBox {
        var kinds = boxes.map(\.kind)
        // A binary operator that cannot be binary (start of row, after an operator, relation, opening, punctuation) is unary.
        for k in kinds.indices where kinds[k] == .binary {
            let prev = k == 0 ? nil : kinds[k - 1]
            let next = k + 1 < kinds.count ? kinds[k + 1] : nil
            if prev == nil || [.binary, .relation, .open, .punctuation, .op].contains(prev!) || next == nil || [.relation, .close, .punctuation].contains(next!) {
                kinds[k] = .ordinary
            }
        }
        var gaps: [CGFloat] = []
        let e = em(s)
        for k in boxes.indices.dropLast() {
            gaps.append(Self.space(kinds[k], kinds[k + 1], script: s.level > 0) * e)
        }
        var width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0
        var offsets: [CGFloat] = []
        for (k, b) in boxes.enumerated() {
            offsets.append(width); width += b.width + (k < gaps.count ? gaps[k] : 0)
            ascent = max(ascent, b.ascent); descent = max(descent, b.descent)
        }
        let kind: MathKind = boxes.count == 1 ? boxes[0].kind : .ordinary
        return MathBox(width: max(0, width), ascent: ascent, descent: descent, kind: kind) { ctx, x, y in
            for (k, b) in boxes.enumerated() { b.draw(ctx, x + offsets[k], y) }
        }
    }

    static func space(_ a: MathKind, _ b: MathKind, script: Bool) -> CGFloat {
        let thin: CGFloat = 3.0 / 18, medium: CGFloat = 4.0 / 18, thick: CGFloat = 5.0 / 18
        func norm(_ k: MathKind) -> MathKind { k == .variable ? .ordinary : k }
        let (l, r) = (norm(a), norm(b))
        if l == .function || l == .op { return [.ordinary, .function, .op].contains(r) ? thin : 0 }
        if r == .function || r == .op { return [.ordinary, .close].contains(l) ? thin : 0 }
        if l == .binary || r == .binary { return script ? 0 : medium }
        if l == .relation || r == .relation { return script || l == r ? 0 : thick }
        if l == .punctuation { return script ? 0 : thin }
        return 0
    }

    // MARK: nodes

    func layout(_ node: MathNode, _ s: Style, font fontStyle: MathFontStyle? = nil) -> MathBox {
        switch node {
        case .atom(let text, let kind):
            return atom(text, kind, s, fontStyle)
        case .row(let nodes):
            return hbox(nodes.map { layout($0, s, font: fontStyle) }, s)
        case .space(let w):
            return .empty(w * em(s))
        case .styled(let inner, let style):
            return layout(inner, s, font: style)
        case .fraction(let num, let den, let hasRule):
            return fraction(num, den, rule: hasRule, s, fontStyle)
        case .scripts(let base, let sup, let sub):
            return scripts(layout(base, s, font: fontStyle), sup: sup, sub: sub, s, fontStyle, italicBase: Self.isItalic(base))
        case .radical(let inner, let index):
            return radical(inner, index: index, s, fontStyle)
        case .largeOp(let glyph, let sup, let sub, let integral, let limits):
            return largeOp(glyph, sup: sup, sub: sub, integral: integral, limits: limits, s, fontStyle)
        case .fenced(let l, let inner, let r):
            let content = layout(inner, s, font: fontStyle)
            return fenced(l, content, r, s)
        case .matrix(let rows, let l, let r, let align, let spread):
            return matrix(rows, left: l, right: r, align: align, spread: spread, s, fontStyle)
        case .accent(let inner, let accent):
            return self.accent(layout(inner, s, font: fontStyle), accent, s)
        }
    }

    static func isItalic(_ node: MathNode) -> Bool { if case .atom(_, .variable) = node { return true } else { return false } }

    func atom(_ text: String, _ kind: MathKind, _ s: Style, _ style: MathFontStyle?) -> MathBox {
        switch style {
        case .text?: return glyphs(text, s, italic: false, kind: .ordinary)
        case .roman?: return glyphs(text, s, italic: false, kind: kind == .variable ? .ordinary : kind)
        case .bold?: return glyphs(text, s, italic: false, bold: true, kind: kind == .variable ? .ordinary : kind)
        case .italic?: return glyphs(text, s, italic: true, kind: kind)
        case .blackboard?: return glyphs(Self.mapped(text, Self.doubleStruck), s, italic: false, kind: .ordinary)
        case .calligraphic?: return glyphs(Self.mapped(text, Self.script), s, italic: false, kind: .ordinary)
        case nil:
            switch kind {
            case .variable: return glyphs(text, s, italic: true, kind: .variable)
            case .function: return glyphs(text, s, italic: false, kind: .function)
            default: return glyphs(text, s, italic: false, kind: kind)
            }
        }
    }

    static let doubleStruck: [Character: String] = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ", "1": "𝟙"]
    static let script: [Character: String] = ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ"]
    static func mapped(_ text: String, _ table: [Character: String]) -> String {
        text.map { c -> String in
            if let m = table[c] { return m }
            guard let v = c.unicodeScalars.first?.value, c.isASCII, c.isUppercase else { return String(c) }
            let base: UInt32 = table == doubleStruck ? 0x1D538 : 0x1D49C
            return UnicodeScalar(base + v - 65).map { String(Character($0)) } ?? String(c)
        }.joined()
    }

    func fraction(_ num: MathNode, _ den: MathNode, rule hasRule: Bool, _ s: Style, _ fs: MathFontStyle?) -> MathBox {
        let inner = Style(level: display && s.level == 0 ? 0 : min(2, s.level + 1))
        let n = layout(num, inner, font: fs), d = layout(den, Style(level: inner.level, cramped: true), font: fs)
        let t = hasRule ? rule(s) : 0, a = axis(s)
        let gap = (display && s.level == 0 ? 0.16 : 0.1) * em(s)
        let pad = 0.12 * em(s)
        let width = max(n.width, d.width) + pad * 2
        let numBaseline = a + t / 2 + gap + n.descent          // above the baseline (positive = up)
        let denBaseline = a - t / 2 - gap - d.ascent           // usually negative
        let color = self.color
        return MathBox(width: width, ascent: numBaseline + n.ascent, descent: max(0, -denBaseline + d.descent), kind: .ordinary) { ctx, x, y in
            n.draw(ctx, x + (width - n.width) / 2, y - numBaseline)
            d.draw(ctx, x + (width - d.width) / 2, y - denBaseline)
            if t > 0 {
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: x + pad * 0.5, y: y - a - t / 2, width: width - pad, height: t))
            }
        }
    }

    func scripts(_ base: MathBox, sup: MathNode?, sub: MathNode?, _ s: Style, _ fs: MathFontStyle?, italicBase: Bool) -> MathBox {
        let ss = Style(level: min(2, s.level + 1))
        let p = sup.map { layout($0, ss, font: fs) }, b = sub.map { layout($0, Style(level: ss.level, cramped: true), font: fs) }
        let e = em(s)
        var supShift = max(base.ascent - 0.25 * e, (s.cramped ? 0.3 : 0.36) * e)
        var subShift = max(base.descent + 0.05 * e, 0.16 * e)
        if let p, let b {
            let gap = (supShift - p.descent) - (b.ascent - subShift)
            if gap < 0.12 * e { subShift += 0.12 * e - gap }
            supShift = max(supShift, p.descent + 0.1 * e)
        }
        let kern: CGFloat = italicBase ? 0.05 * e : 0.02 * e
        let scriptWidth = max(p?.width ?? 0, b?.width ?? 0)
        let ascent = max(base.ascent, supShift + (p?.ascent ?? 0))
        let descent = max(base.descent, b.map { subShift + $0.descent } ?? 0)
        return MathBox(width: base.width + kern + scriptWidth + 0.03 * e, ascent: ascent, descent: descent, kind: base.kind) { ctx, x, y in
            base.draw(ctx, x, y)
            p?.draw(ctx, x + base.width + kern, y - supShift)
            b?.draw(ctx, x + base.width + (italicBase ? 0 : kern), y + subShift)
        }
    }

    func radical(_ inner: MathNode, index: MathNode?, _ s: Style, _ fs: MathFontStyle?) -> MathBox {
        let c = layout(inner, Style(level: s.level, cramped: true), font: fs)
        let e = em(s), t = rule(s)
        let gap = (display && s.level == 0 ? 0.2 : 0.12) * e
        let signWidth = 0.56 * e
        let top = c.ascent + gap + t
        let bottom = c.descent
        let idx = index.map { layout($0, Style(level: 2), font: fs) }
        let idxWidth = max(0, (idx?.width ?? 0) - signWidth * 0.45)
        let color = self.color
        return MathBox(width: idxWidth + signWidth + c.width + 0.08 * e, ascent: top + t * 0.5 + (idx != nil ? max(0, (idx!.ascent + idx!.descent) - top * 0.4) : 0), descent: bottom + 0.04 * e) { ctx, x, y in
            let x0 = x + idxWidth
            let path = CGMutablePath()
            let midY = y - (top - bottom) * 0.35 + bottom * 0.3
            path.move(to: CGPoint(x: x0, y: midY + 0.02 * e))
            path.addLine(to: CGPoint(x: x0 + signWidth * 0.22, y: midY - 0.06 * e))
            path.addLine(to: CGPoint(x: x0 + signWidth * 0.5, y: y + bottom))
            path.addLine(to: CGPoint(x: x0 + signWidth * 0.92, y: y - top + t / 2))
            path.addLine(to: CGPoint(x: x0 + signWidth + c.width + 0.06 * e, y: y - top + t / 2))
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(t); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.addPath(path); ctx.strokePath()
            c.draw(ctx, x0 + signWidth, y)
            if let idx { idx.draw(ctx, x, y - (top * 0.42) - idx.descent) }
        }
    }

    func largeOp(_ glyph: String, sup: MathNode?, sub: MathNode?, integral: Bool, limits: Bool, _ s: Style, _ fs: MathFontStyle?) -> MathBox {
        let isWord = glyph.first?.isLetter == true
        let big = display && s.level == 0
        let scale: CGFloat = isWord ? 1 : integral ? (big ? 1.9 : 1.3) : (big ? 1.55 : 1.15)
        var op = glyphs(glyph, s, italic: false, scale: scale, kind: .op)
        if !isWord {
            // Centre the operator glyph on the math axis.
            let a = axis(s), h = op.ascent + op.descent, shift = (op.ascent - op.descent) / 2 - a
            let inner = op
            op = MathBox(width: inner.width, ascent: h / 2 + a, descent: h / 2 - a, kind: .op) { ctx, x, y in inner.draw(ctx, x, y + shift) }
        }
        guard sup != nil || sub != nil else { return op }
        if limits && (big || isWord) {
            let ss = Style(level: min(2, s.level + 1))
            let p = sup.map { layout($0, ss, font: fs) }, b = sub.map { layout($0, Style(level: ss.level, cramped: true), font: fs) }
            let gap = 0.12 * em(s)
            let width = max(op.width, p?.width ?? 0, b?.width ?? 0)
            let ascent = op.ascent + (p.map { gap + $0.ascent + $0.descent } ?? 0)
            let descent = op.descent + (b.map { gap + $0.ascent + $0.descent } ?? 0)
            return MathBox(width: width, ascent: ascent, descent: descent, kind: .op) { ctx, x, y in
                op.draw(ctx, x + (width - op.width) / 2, y)
                if let p { p.draw(ctx, x + (width - p.width) / 2, y - op.ascent - gap - p.descent) }
                if let b { b.draw(ctx, x + (width - b.width) / 2, y + op.descent + gap + b.ascent) }
            }
        }
        let box = scripts(op, sup: sup, sub: sub, s, fs, italicBase: integral)
        box.kind = .op
        return box
    }

    func fenced(_ l: String, _ content: MathBox, _ r: String, _ s: Style) -> MathBox {
        let a = axis(s)
        let half = max(content.ascent - a, content.descent + a, 0.5 * em(s)) + 0.08 * em(s)
        let left = delimiter(l, half: half, s), right = delimiter(r, half: half, s)
        let inner = hbox([left, content, right].map { $0 }, Style(level: s.level))
        return MathBox(width: inner.width, ascent: max(inner.ascent, half + a), descent: max(inner.descent, half - a), kind: .ordinary, draw: inner.draw)
    }

    /// A delimiter centred on the axis, `half` tall above and below it; drawn as a path once it outgrows the font glyph.
    func delimiter(_ d: String, half: CGFloat, _ s: Style) -> MathBox {
        guard d != "." else { return .empty(0.06 * em(s)) }
        let e = em(s), a = axis(s), t = rule(s) * 1.05
        let h = half * 2
        if h <= e * 1.25 {
            let g = glyphs(d, s, italic: false, kind: d == "(" || d == "[" || d == "{" || d == "⟨" || d == "⌊" || d == "⌈" ? .open : .close)
            return g
        }
        let width: CGFloat = d == "{" || d == "}" ? 0.5 * e : d == "|" || d == "‖" ? 0.32 * e : 0.42 * e
        let color = self.color
        let kind: MathKind = "([{⟨⌊⌈".contains(d) ? .open : "|‖".contains(d) ? .ordinary : .close
        return MathBox(width: width, ascent: half + a, descent: half - a, kind: kind) { ctx, x, y in
            let top = y - a - half, bottom = y - a + half, mid = y - a
            let p = CGMutablePath()
            let inset = width * 0.22
            switch d {
            case "(":
                p.move(to: CGPoint(x: x + width - inset, y: top)); p.addQuadCurve(to: CGPoint(x: x + width - inset, y: bottom), control: CGPoint(x: x - width * 0.35, y: mid))
            case ")":
                p.move(to: CGPoint(x: x + inset, y: top)); p.addQuadCurve(to: CGPoint(x: x + inset, y: bottom), control: CGPoint(x: x + width * 1.35, y: mid))
            case "[", "⌊", "⌈":
                p.move(to: CGPoint(x: x + width - inset, y: top)); p.addLine(to: CGPoint(x: x + inset * 1.4, y: top))
                p.addLine(to: CGPoint(x: x + inset * 1.4, y: bottom)); p.addLine(to: CGPoint(x: x + width - inset, y: bottom))
                if d == "⌊" { p.move(to: CGPoint(x: x + inset * 1.4, y: top)) }
            case "]", "⌋", "⌉":
                p.move(to: CGPoint(x: x + inset, y: top)); p.addLine(to: CGPoint(x: x + width - inset * 1.4, y: top))
                p.addLine(to: CGPoint(x: x + width - inset * 1.4, y: bottom)); p.addLine(to: CGPoint(x: x + inset, y: bottom))
            case "{":
                let cx = x + width * 0.5
                p.move(to: CGPoint(x: x + width - inset, y: top))
                p.addQuadCurve(to: CGPoint(x: cx, y: top + half * 0.25), control: CGPoint(x: cx, y: top))
                p.addLine(to: CGPoint(x: cx, y: mid - half * 0.2))
                p.addQuadCurve(to: CGPoint(x: x + inset * 0.6, y: mid), control: CGPoint(x: cx, y: mid))
                p.addQuadCurve(to: CGPoint(x: cx, y: mid + half * 0.2), control: CGPoint(x: cx, y: mid))
                p.addLine(to: CGPoint(x: cx, y: bottom - half * 0.25))
                p.addQuadCurve(to: CGPoint(x: x + width - inset, y: bottom), control: CGPoint(x: cx, y: bottom))
            case "}":
                let cx = x + width * 0.5
                p.move(to: CGPoint(x: x + inset, y: top))
                p.addQuadCurve(to: CGPoint(x: cx, y: top + half * 0.25), control: CGPoint(x: cx, y: top))
                p.addLine(to: CGPoint(x: cx, y: mid - half * 0.2))
                p.addQuadCurve(to: CGPoint(x: x + width - inset * 0.6, y: mid), control: CGPoint(x: cx, y: mid))
                p.addQuadCurve(to: CGPoint(x: cx, y: mid + half * 0.2), control: CGPoint(x: cx, y: mid))
                p.addLine(to: CGPoint(x: cx, y: bottom - half * 0.25))
                p.addQuadCurve(to: CGPoint(x: x + inset, y: bottom), control: CGPoint(x: cx, y: bottom))
            case "⟨":
                p.move(to: CGPoint(x: x + width - inset, y: top)); p.addLine(to: CGPoint(x: x + inset, y: mid)); p.addLine(to: CGPoint(x: x + width - inset, y: bottom))
            case "⟩":
                p.move(to: CGPoint(x: x + inset, y: top)); p.addLine(to: CGPoint(x: x + width - inset, y: mid)); p.addLine(to: CGPoint(x: x + inset, y: bottom))
            case "‖":
                p.move(to: CGPoint(x: x + width * 0.3, y: top)); p.addLine(to: CGPoint(x: x + width * 0.3, y: bottom))
                p.move(to: CGPoint(x: x + width * 0.7, y: top)); p.addLine(to: CGPoint(x: x + width * 0.7, y: bottom))
            default:
                p.move(to: CGPoint(x: x + width / 2, y: top)); p.addLine(to: CGPoint(x: x + width / 2, y: bottom))
            }
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(t); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(p); ctx.strokePath()
        }
    }

    func matrix(_ rows: [[MathNode]], left: String, right: String, align: [Character], spread: CGFloat, _ s: Style, _ fs: MathFontStyle?) -> MathBox {
        let cells = rows.map { $0.map { layout($0, s, font: fs) } }
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 0 else { return .empty() }
        let e = em(s)
        var colWidths = Array(repeating: CGFloat(0), count: columns)
        for row in cells { for (c, b) in row.enumerated() { colWidths[c] = max(colWidths[c], b.width) } }
        let rowAscents = cells.map { max($0.map(\.ascent).max() ?? 0, 0.7 * e) }
        let rowDescents = cells.map { max($0.map(\.descent).max() ?? 0, 0.25 * e) }
        let rowGap = (spread > 0 ? 0.3 : 0.25) * e
        let colGap: CGFloat = spread > 0 ? 0.9 * e : 0.12 * e
        let height = zip(rowAscents, rowDescents).reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(max(0, cells.count - 1))
        let a = axis(s)
        let width = colWidths.reduce(0, +) + colGap * CGFloat(columns - 1)
        let body = MathBox(width: width, ascent: height / 2 + a, descent: height / 2 - a) { ctx, x, y in
            var top = y - a - height / 2
            for (r, row) in cells.enumerated() {
                let baseline = top + rowAscents[r]
                var cx = x
                for c in 0..<columns {
                    if c < row.count {
                        let b = row[c]
                        let al = align.isEmpty ? "c" : align[min(c, align.count - 1) % max(1, align.count)]
                        let alignment: Character = align.count == 2 && align == ["r", "l"] ? (c % 2 == 0 ? "r" : "l") : al
                        let dx: CGFloat = alignment == "l" ? 0 : alignment == "r" ? colWidths[c] - b.width : (colWidths[c] - b.width) / 2
                        b.draw(ctx, cx + dx, baseline)
                    }
                    cx += colWidths[c] + colGap
                }
                top = baseline + rowDescents[r] + rowGap
            }
        }
        if left == "." && right == "." { return body }
        return fenced(left, body, right, s)
    }

    func accent(_ c: MathBox, _ accent: MathAccent, _ s: Style) -> MathBox {
        let e = em(s), t = rule(s)
        let gap = 0.08 * e
        let color = self.color
        let extra: CGFloat
        switch accent {
        case .underline: extra = 0
        case .dot, .ddot: extra = 0.14 * e
        case .vec: extra = 0.2 * e
        default: extra = 0.16 * e
        }
        let descent = accent == .underline ? c.descent + gap + t * 2 : c.descent
        return MathBox(width: c.width, ascent: c.ascent + (accent == .underline ? 0 : gap + extra), descent: descent, kind: c.kind) { ctx, x, y in
            c.draw(ctx, x, y)
            let top = y - c.ascent - gap
            ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor); ctx.setLineWidth(t); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let mid = x + c.width / 2
            let w = max(c.width * 0.9, 0.36 * e)
            switch accent {
            case .bar, .overline:
                let span = accent == .overline ? c.width : w
                ctx.move(to: CGPoint(x: mid - span / 2, y: top - extra / 2)); ctx.addLine(to: CGPoint(x: mid + span / 2, y: top - extra / 2)); ctx.strokePath()
            case .underline:
                ctx.move(to: CGPoint(x: x, y: y + c.descent + gap)); ctx.addLine(to: CGPoint(x: x + c.width, y: y + c.descent + gap)); ctx.strokePath()
            case .hat:
                let hw = min(w, 0.5 * e) / 2
                ctx.move(to: CGPoint(x: mid - hw, y: top)); ctx.addLine(to: CGPoint(x: mid, y: top - extra)); ctx.addLine(to: CGPoint(x: mid + hw, y: top)); ctx.strokePath()
            case .tilde:
                let hw = min(w, 0.5 * e) / 2
                ctx.move(to: CGPoint(x: mid - hw, y: top - extra * 0.3))
                ctx.addCurve(to: CGPoint(x: mid + hw, y: top - extra * 0.7), control1: CGPoint(x: mid - hw * 0.3, y: top - extra * 1.4), control2: CGPoint(x: mid + hw * 0.3, y: top + extra * 0.4))
                ctx.strokePath()
            case .vec:
                let span = max(c.width, 0.4 * e)
                let yv = top - extra / 2
                ctx.move(to: CGPoint(x: mid - span / 2, y: yv)); ctx.addLine(to: CGPoint(x: mid + span / 2, y: yv))
                ctx.move(to: CGPoint(x: mid + span / 2 - 0.12 * e, y: yv - 0.08 * e)); ctx.addLine(to: CGPoint(x: mid + span / 2, y: yv))
                ctx.addLine(to: CGPoint(x: mid + span / 2 - 0.12 * e, y: yv + 0.08 * e)); ctx.strokePath()
            case .dot:
                ctx.fillEllipse(in: CGRect(x: mid - 0.05 * e, y: top - extra * 0.8, width: 0.1 * e, height: 0.1 * e))
            case .ddot:
                for dx in [-0.11 * e, 0.11 * e] { ctx.fillEllipse(in: CGRect(x: mid + dx - 0.05 * e, y: top - extra * 0.8, width: 0.1 * e, height: 0.1 * e)) }
            }
        }
    }
}

// MARK: - Rendering + cache

enum MathRenderer {
    struct Rendered { let image: UIImage; let descent: CGFloat; let size: CGSize }
    private final class Box { let value: Rendered?; init(_ v: Rendered?) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 400; return c }()   // NSCache is thread-safe

    /// nil when the source is not valid (supported) LaTeX.
    @MainActor static func render(_ latex: String, display: Bool, fontSize: CGFloat, color: UIColor) -> Rendered? {
        let key = "\(display ? 1 : 0)|\(fontSize)|\(color.hexKey)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let result = make(latex, display: display, fontSize: fontSize, color: color)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    @MainActor private static func make(_ latex: String, display: Bool, fontSize: CGFloat, color: UIColor) -> Rendered? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, var parser = try? MathParser(source), let tree = try? parser.parseDocument() else { return nil }
        let engine = MathLayout(base: fontSize, color: color, display: display)
        let box = engine.layout(tree, .init(level: 0))
        guard box.width > 0, box.width < 4000 else { return nil }
        let pad: CGFloat = 1.5
        let size = CGSize(width: ceil(box.width + pad * 2), height: ceil(box.ascent + box.descent + pad * 2))
        let format = UIGraphicsImageRendererFormat.preferred(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            box.draw(context.cgContext, pad, pad + box.ascent)
        }
        return Rendered(image: image, descent: box.descent + pad, size: size)
    }
}

private extension UIColor {
    var hexKey: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02x%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
}

/// Display math: centred, scrolls horizontally when wider than the column, never clipped. Unsupported or malformed input is
/// shown as its LaTeX source in code style with a short note, not as broken escape sequences inside prose.
struct MathBlockView: View {
    let latex: String
    var closed = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 18

    var body: some View {
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        if closed, let rendered = MathRenderer.render(latex, display: true, fontSize: fontSize, color: color) {
            let image = Image(uiImage: rendered.image).frame(width: rendered.size.width, height: rendered.size.height).padding(.vertical, 4)
            // Centred when it fits (as KaTeX display math); a wide formula scrolls instead of being clipped or shrunk.
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal) { image }.scrollIndicators(.visible)
            }
            .accessibilityElement().accessibilityLabel("公式").accessibilityValue(latex)
            .accessibilityIdentifier("markdown.math")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal) {
                    Text(latex).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }.scrollIndicators(.hidden)
                Text(closed ? "这个公式无法排版，显示原文" : "公式输入中…").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(MarkdownStyle.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("markdown.math.source")
        }
    }
}
