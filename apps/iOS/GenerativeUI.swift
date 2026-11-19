import SwiftUI
import Charts
import UIKit
import CryptoKit

// Model-driven UI ("italk-ui"): the model writes a declarative JSON document inside a ```italk-ui fence; this file parses it
// (tolerating half-streamed JSON), evaluates bindings with a small sandboxed expression language, keeps per-interface state
// (persisted, so interactions survive relaunch and completed actions are never repeated) and renders it with native SwiftUI.
// Nothing in a document can run code: components are a fixed vocabulary, expressions are pure arithmetic/logic over the
// interface's own state, links must be https, and anything that leaves the interface goes through the normal agent turn.

// MARK: - JSON value

enum UIValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([UIValue]), object([String: UIValue])

    init(any: Any?) {
        switch any {
        case let n as NSNumber: self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { UIValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { UIValue(any: $0) })
        default: self = .null
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([UIValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: UIValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): Self.format(n)
        case .string(let s): s
        case .array(let a): a.map(\.string).joined(separator: ", ")
        case .object: ""
        }
    }
    var number: Double? {
        switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): !s.isEmpty && s != "false"
        case .array(let a): !a.isEmpty
        case .object: true
        }
    }
    subscript(_ key: String) -> UIValue? { if case .object(let o) = self { o[key] } else { nil } }
    var array: [UIValue]? { if case .array(let a) = self { a } else { nil } }
    static func format(_ n: Double) -> String {
        if n.isNaN || n.isInfinite { return "—" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(format: "%.4g", n)
    }
}

// MARK: - Partial JSON

enum PartialJSON {
    /// Closes whatever a half-streamed JSON document left open (strings, arrays, objects) and drops a dangling key or
    /// separator, so the part that has arrived can already be rendered.
    static func repair(_ text: String) -> String? {
        var stack: [Character] = [], inString = false, escaped = false
        var lastSafe = text.startIndex
        var out = text
        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": stack.append(c)
            case "}", "]": if !stack.isEmpty { stack.removeLast() }; lastSafe = text.index(after: i)
            case ",": lastSafe = i
            default: break
            }
        }
        if inString { out += "\"" }
        // Trim a trailing `,` / `"key":` / `"key"` that cannot stand alone.
        var trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == "," || last == ":" { trimmed.removeLast(); trimmed = trimmed.trimmingCharacters(in: .whitespaces) }
        if trimmed.hasSuffix("\""), stack.last == "{" {
            // An object member without a value: cut back to the last separator.
            if let comma = trimmed.lastIndex(where: { $0 == "," || $0 == "{" }), trimmed[comma...].contains(":") == false {
                trimmed = String(trimmed[..<comma]) + (trimmed[comma] == "{" ? "{" : "")
            }
        }
        _ = lastSafe
        // Recount the stack on the trimmed text.
        stack = []; inString = false; escaped = false
        for c in trimmed {
            if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
            if c == "\"" { inString = true } else if c == "{" || c == "[" { stack.append(c) } else if c == "}" || c == "]" { if !stack.isEmpty { stack.removeLast() } }
        }
        if inString { trimmed += "\"" }
        for open in stack.reversed() { trimmed += open == "{" ? "}" : "]" }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(_ text: String, complete: Bool) -> UIValue? {
        let source = complete ? text : (repair(text) ?? "")
        guard let data = source.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return UIValue(any: any)
    }
}

// MARK: - Expressions

/// `{{ … }}` bindings: numbers, strings, state keys (a.b for nested), + − × ÷ % ^, comparisons, && || !, ternary,
/// and a few pure functions. No assignments, no loops, no access to anything outside the interface's state.
struct UIExpression {
    enum Token: Equatable { case num(Double), str(String), ident(String), op(String), lparen, rparen, comma, question, colon }
    let tokens: [Token]
    var i = 0
    let state: [String: UIValue]

    static func evaluate(_ source: String, state: [String: UIValue]) -> UIValue {
        guard let tokens = tokenize(source) else { return .null }
        var e = UIExpression(tokens: tokens, state: state)
        guard let v = e.ternary(), e.i == tokens.count else { return .null }
        return v
    }

    /// Replaces every `{{expr}}`; a string that is exactly one binding keeps the value's type.
    static func resolve(_ value: UIValue, state: [String: UIValue]) -> UIValue {
        guard case .string(let s) = value, s.contains("{{") else { return value }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.components(separatedBy: "{{").count == 2 {
            return evaluate(String(trimmed.dropFirst(2).dropLast(2)), state: state)
        }
        var out = "", rest = Substring(s)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += rest[open.lowerBound...]; rest = ""; break }
            out += evaluate(String(rest[open.upperBound..<close.lowerBound]), state: state).string
            rest = rest[close.upperBound...]
        }
        return .string(out + rest)
    }

    static func tokenize(_ s: String) -> [Token]? {
        var out: [Token] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isNumber || (ch == "." && i + 1 < c.count && c[i + 1].isNumber) {
                var j = i; while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }
                guard let n = Double(String(c[i..<j])) else { return nil }
                out.append(.num(n)); i = j; continue
            }
            if ch.isLetter || ch == "_" || ch == "$" {
                var j = i; while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "." || c[j] == "$" { j += 1 }
                out.append(.ident(String(c[i..<j]))); i = j; continue
            }
            if ch == "'" || ch == "\"" {
                var j = i + 1, str = ""
                while j < c.count, c[j] != ch { str.append(c[j]); j += 1 }
                guard j < c.count else { return nil }
                out.append(.str(str)); i = j + 1; continue
            }
            let two = i + 1 < c.count ? String([ch, c[i + 1]]) : ""
            if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) { out.append(.op(two)); i += 2; continue }
            switch ch {
            case "+", "-", "*", "/", "%", "^", "<", ">", "!": out.append(.op(String(ch)))
            case "×": out.append(.op("*"))
            case "÷": out.append(.op("/"))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case ",": out.append(.comma)
            case "?": out.append(.question)
            case ":": out.append(.colon)
            default: return nil
            }
            i += 1
        }
        return out.count > 400 ? nil : out
    }

    var peek: Token? { i < tokens.count ? tokens[i] : nil }
    mutating func eat(_ t: Token) -> Bool { if peek == t { i += 1; return true }; return false }

    mutating func ternary() -> UIValue? {
        guard let cond = or() else { return nil }
        if eat(.question) {
            guard let a = ternary(), eat(.colon), let b = ternary() else { return nil }
            return cond.truthy ? a : b
        }
        return cond
    }
    mutating func or() -> UIValue? {
        guard var l = and() else { return nil }
        while eat(.op("||")) { guard let r = and() else { return nil }; l = .bool(l.truthy || r.truthy) }
        return l
    }
    mutating func and() -> UIValue? {
        guard var l = compare() else { return nil }
        while eat(.op("&&")) { guard let r = compare() else { return nil }; l = .bool(l.truthy && r.truthy) }
        return l
    }
    mutating func compare() -> UIValue? {
        guard var l = sum() else { return nil }
        while case .op(let o)? = peek, ["==", "!=", "<", "<=", ">", ">="].contains(o) {
            i += 1
            guard let r = sum() else { return nil }
            if let a = l.number, let b = r.number, o != "==" && o != "!=" || (l.number != nil && r.number != nil && !(isString(l) || isString(r))) {
                switch o { case "==": l = .bool(a == b); case "!=": l = .bool(a != b); case "<": l = .bool(a < b); case "<=": l = .bool(a <= b)
                case ">": l = .bool(a > b); default: l = .bool(a >= b) }
            } else {
                switch o { case "==": l = .bool(l.string == r.string); case "!=": l = .bool(l.string != r.string)
                case "<": l = .bool(l.string < r.string); case ">": l = .bool(l.string > r.string)
                case "<=": l = .bool(l.string <= r.string); default: l = .bool(l.string >= r.string) }
            }
        }
        return l
    }
    func isString(_ v: UIValue) -> Bool { if case .string(let s) = v { return Double(s) == nil } else { return false } }
    mutating func sum() -> UIValue? {
        guard var l = product() else { return nil }
        while case .op(let o)? = peek, o == "+" || o == "-" {
            i += 1
            guard let r = product() else { return nil }
            if o == "+", isString(l) || isString(r) { l = .string(l.string + r.string) }
            else if let a = l.number, let b = r.number { l = .number(o == "+" ? a + b : a - b) } else { return .null }
        }
        return l
    }
    mutating func product() -> UIValue? {
        guard var l = power() else { return nil }
        while case .op(let o)? = peek, o == "*" || o == "/" || o == "%" {
            i += 1
            guard let r = power(), let a = l.number, let b = r.number else { return .null }
            l = .number(o == "*" ? a * b : o == "/" ? (b == 0 ? .nan : a / b) : (b == 0 ? .nan : a.truncatingRemainder(dividingBy: b)))
        }
        return l
    }
    mutating func power() -> UIValue? {
        guard let base = unary() else { return nil }
        if eat(.op("^")) { guard let e = power(), let a = base.number, let b = e.number else { return .null }; return .number(pow(a, b)) }
        return base
    }
    mutating func unary() -> UIValue? {
        if eat(.op("-")) { guard let v = unary(), let n = v.number else { return .null }; return .number(-n) }
        if eat(.op("!")) { guard let v = unary() else { return nil }; return .bool(!v.truthy) }
        return primary()
    }
    mutating func primary() -> UIValue? {
        guard let t = peek else { return nil }
        i += 1
        switch t {
        case .num(let n): return .number(n)
        case .str(let s): return .string(s)
        case .lparen:
            let v = ternary()
            return eat(.rparen) ? v : nil
        case .ident(let name):
            if eat(.lparen) {
                var args: [UIValue] = []
                if !eat(.rparen) {
                    repeat { guard let a = ternary() else { return nil }; args.append(a) } while eat(.comma)
                    guard eat(.rparen) else { return nil }
                }
                return Self.call(name, args)
            }
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "pi", "PI": return .number(.pi)
            case "e", "E": return .number(M_E)
            default: return lookup(name)
            }
        default: return nil
        }
    }
    func lookup(_ path: String) -> UIValue {
        var parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return .null }
        var value = state[parts.removeFirst()] ?? .null
        for p in parts {
            if p == "length", let a = value.array { value = .number(Double(a.count)); continue }
            if let index = Int(p), let a = value.array { value = index < a.count ? a[index] : .null; continue }
            value = value[p] ?? .null
        }
        return value
    }
    static func call(_ name: String, _ a: [UIValue]) -> UIValue {
        let n = a.map { $0.number ?? .nan }
        func one(_ f: (Double) -> Double) -> UIValue { n.count == 1 ? .number(f(n[0])) : .null }
        switch name {
        case "min": return n.isEmpty ? .null : .number(n.min()!)
        case "max": return n.isEmpty ? .null : .number(n.max()!)
        case "abs": return one(abs)
        case "sqrt": return one(sqrt)
        case "floor": return one(floor)
        case "ceil": return one(ceil)
        case "sin": return one(sin)
        case "cos": return one(cos)
        case "tan": return one(tan)
        case "log", "ln": return one(log)
        case "log10": return one(log10)
        case "exp": return one(exp)
        case "pow": return n.count == 2 ? .number(pow(n[0], n[1])) : .null
        case "round":
            guard let x = n.first else { return .null }
            let digits = n.count > 1 ? n[1] : 0
            let m = pow(10, digits)
            return .number((x * m).rounded() / m)
        case "fixed":
            guard let x = n.first else { return .null }
            return .string(String(format: "%.\(Int(n.count > 1 ? max(0, min(8, n[1])) : 2))f", x))
        case "percent":
            guard let x = n.first else { return .null }
            return .string(String(format: "%.\(Int(n.count > 1 ? max(0, min(4, n[1])) : 0))f%%", x * 100))
        case "len": return .number(Double(a.first?.array?.count ?? a.first?.string.count ?? 0))
        case "sum": return .number(a.first?.array?.compactMap(\.number).reduce(0, +) ?? 0)
        case "contains":
            guard a.count == 2 else { return .null }
            if let arr = a[0].array { return .bool(arr.contains(a[1])) }
            return .bool(a[0].string.contains(a[1].string))
        case "if": return a.count == 3 ? (a[0].truthy ? a[1] : a[2]) : .null
        default: return .null
        }
    }
}

// MARK: - State and persistence

/// State of every generated interface, keyed by its document id, plus the actions that already left the interface
/// (messages sent, tool requests). Persisted in Application Support so a restored conversation shows the same state and
/// never offers a completed one-shot action again. Visual-only; nothing here grants a capability.
@MainActor @Observable final class GenUIStore {
    static let shared = GenUIStore()
    private(set) var states: [String: [String: UIValue]] = [:]
    private(set) var completed: [String: Set<String>] = [:]
    /// Bumped on every change so views that render an interface re-evaluate even when they sit under an Equatable ancestor.
    private(set) var revision = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL = {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("iTalk", isDirectory: true) ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("generated-ui-state.json")
    }()

    private struct Snapshot: Codable { var states: [String: [String: UIValue]]; var completed: [String: [String]] }

    init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            states = s.states; completed = s.completed.mapValues(Set.init)
        }
    }

    func state(_ id: String, initial: [String: UIValue]) -> [String: UIValue] {
        // Keys the model adds in a later version of the same interface start from their new initial value.
        initial.merging(states[id] ?? [:]) { _, saved in saved }
    }
    func set(_ id: String, _ key: String, _ value: UIValue, initial: [String: UIValue]) {
        var s = state(id, initial: initial); s[key] = value; states[id] = s; revision &+= 1; scheduleSave()
    }
    func isDone(_ id: String, _ action: String) -> Bool { completed[id]?.contains(action) == true }
    func markDone(_ id: String, _ action: String) { completed[id, default: []].insert(action); revision &+= 1; scheduleSave() }
    // Reset the form values, not one-shot actions that may already have reached a remote computer.
    func reset(_ id: String) { states[id] = nil; revision &+= 1; scheduleSave() }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(states: states, completed: completed.mapValues { Array($0) })
        let url = self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// What a generated interface may do outside itself. `send` posts a visible user message to the same conversation (the model
/// answers, and any tool it decides to call goes through the normal approval flow). Injected by the conversation screen.
struct GenUIHandler: @unchecked Sendable {
    var send: @MainActor (_ text: String, _ idempotencyKey: String) async -> Bool
    var canSend: Bool = true
}
private struct GenUIHandlerKey: EnvironmentKey { static let defaultValue: GenUIHandler? = nil }
// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: Different computers and conversations may emit the same document id.
// Debug Goal: Keep generated controls and one-shot actions scoped to their originating remote task.
// Search Tags: generative ui remote task document id state isolation
// Invariants:
// - The empty namespace preserves the existing local-chat state keys.
// - A missing action handler disables buttons that would send or run a tool.
// Failure Modes:
// - Reusing a model-provided id across tasks leaks selections or completion state.
// - An absent handler leaves a send button looking actionable while it does nothing.
private struct GenUINamespaceKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var genUIHandler: GenUIHandler? {
        get { self[GenUIHandlerKey.self] }
        set { self[GenUIHandlerKey.self] = newValue }
    }
    var genUINamespace: String {
        get { self[GenUINamespaceKey.self] }
        set { self[GenUINamespaceKey.self] = newValue }
    }
}

// MARK: - Document

struct GenUIDocument {
    let id: String
    let title: String?
    let initialState: [String: UIValue]
    let root: UIValue

    static let maxNodes = 400

    init?(_ value: UIValue, fallbackId: String, namespace: String = "") {
        guard case .object(let o) = value else { return nil }
        let rawId: String
        if o["type"] != nil {
            rawId = fallbackId; title = nil; initialState = [:]; root = value
        } else {
            guard let root = o["root"] ?? o["view"] ?? o["body"] else { return nil }
            self.root = root
            rawId = o["id"].map(\.string).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackId
            title = o["title"]?.string
            if case .object(let s)? = o["state"] { initialState = s } else { initialState = [:] }
        }
        id = namespace.isEmpty ? rawId : namespace + ":" + rawId
    }

    static func stableId(_ source: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in source.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "ui-" + String(h, radix: 36)
    }
}

// MARK: - Renderer

/// A ```italk-ui block: progressive while it streams, a quiet notice if it cannot be shown.
struct GenUIBlockView: View {
    let source: String
    let closed: Bool
    @State private var showSource = false
    @Environment(\.genUINamespace) private var namespace

    var body: some View {
        let parsed = PartialJSON.parse(source, complete: closed)
        let document = parsed.flatMap { GenUIDocument($0, fallbackId: GenUIDocument.stableId(source), namespace: namespace) }
        if let document {
            VStack(alignment: .leading, spacing: 8) {
                GenUIDocumentView(document: document, live: !closed)
                if !closed { ShimmerText(text: "正在生成界面…").accessibilityHidden(true) }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("genui.\(document.id)")
        } else if !closed {
            HStack(spacing: 8) { ProgressView().controlSize(.small); ShimmerText(text: "正在生成界面…") }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous))
                .accessibilityIdentifier("genui.loading")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { showSource.toggle() } label: {
                    Label("这个界面无法显示", systemImage: "exclamationmark.triangle").font(.subheadline)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                if showSource { CodeBlockView(language: "json", code: source) }
            }
            .accessibilityIdentifier("genui.invalid")
        }
    }
}

struct GenUIDocumentView: View {
    let document: GenUIDocument
    var live = false
    @State private var revision = 0

    var body: some View {
        let store = GenUIStore.shared
        let _ = revision
        let state = store.state(document.id, initial: document.initialState)
        let context = GenUIContext(id: document.id, state: state, initial: document.initialState, live: live)
        VStack(alignment: .leading, spacing: 10) {
            if let title = document.title, !title.isEmpty { Text(title).font(.headline) }
            GenUINodeView(node: document.root, context: context, depth: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Explicit subscription: an Observation read alone was not enough under the Equatable Markdown block.
        .onChange(of: GenUIStore.shared.revision) { _, value in revision = value }
    }
}

struct GenUIContext {
    let id: String
    let state: [String: UIValue]
    let initial: [String: UIValue]
    let live: Bool
    func value(_ v: UIValue?) -> UIValue { v.map { UIExpression.resolve($0, state: state) } ?? .null }
    func text(_ v: UIValue?) -> String { value(v).string }
    func number(_ v: UIValue?) -> Double? { value(v).number }
}

struct GenUINodeView: View {
    let node: UIValue
    let context: GenUIContext
    let depth: Int
    @State private var store = GenUIStore.shared
    @Environment(\.genUIHandler) private var handler
    @Environment(\.openURL) private var openURL
    @State private var submittingAction = false

    private var type: String { node["type"]?.string.lowercased() ?? "" }
    private var children: [UIValue] { node["children"]?.array ?? node["items"].flatMap { type == "stack" || type == "row" ? $0.array : nil } ?? [] }

    var body: some View {
        if depth > 14 { EmptyView() }
        else if let visible = node["visible"], !context.value(visible).truthy { EmptyView() }
        else { content.modifier(GenUIAccessibility(label: node["accessibilityLabel"].map { context.text($0) })) }
    }

    private func child(_ v: UIValue) -> some View { GenUINodeView(node: v, context: context, depth: depth + 1) }
    private func childList(_ list: [UIValue]) -> some View {
        ForEach(Array(list.prefix(60).enumerated()), id: \.offset) { _, c in child(c) }
    }
    private var spacing: CGFloat { CGFloat(context.number(node["spacing"]) ?? 10) }

    @ViewBuilder private var content: some View {
        switch type {
        // Layout
        case "stack", "vstack", "column":
            let horizontal = context.text(node["direction"]) == "horizontal"
            if horizontal {
                HStack(alignment: verticalAlign, spacing: spacing) { childList(children) }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: horizontalAlign, spacing: spacing) { childList(children) }.frame(maxWidth: .infinity, alignment: frameAlign)
            }
        case "row", "hstack":
            HStack(alignment: verticalAlign, spacing: spacing) { childList(children) }.frame(maxWidth: .infinity, alignment: .leading)
        case "grid":
            let columns = max(1, min(4, Int(context.number(node["columns"]) ?? 2)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: columns), alignment: .leading, spacing: spacing) {
                childList(children)
            }
        case "card", "section":
            VStack(alignment: .leading, spacing: 10) {
                if node["title"] != nil || node["icon"] != nil {
                    HStack(spacing: 8) {
                        if let icon = node["icon"] { Image(systemName: context.text(icon)).foregroundStyle(tone(node["tone"])) }
                        VStack(alignment: .leading, spacing: 2) {
                            if let t = node["title"] { Text(context.text(t)).font(.headline) }
                            if let s = node["subtitle"] { Text(context.text(s)).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
                childList(children)
            }
            .padding(type == "card" ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(type == "card" ? MarkdownStyle.surface : .clear, in: RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous))
        case "scroll", "carousel":
            ScrollView(.horizontal) { HStack(alignment: .top, spacing: spacing) { childList(children) } }.scrollIndicators(.hidden).scrollClipDisabled()
        case "divider": Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5)
        case "spacer": Spacer(minLength: CGFloat(context.number(node["size"]) ?? 8))

        // Display
        case "text":
            Text(context.text(node["value"] ?? node["text"])).font(font(node["style"])).fontWeight(weight(node["weight"]))
                .foregroundStyle(tone(node["tone"] ?? node["color"]))
                .multilineTextAlignment(textAlign).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: node["align"] == nil ? nil : .infinity, alignment: frameAlign)
                .textSelection(.enabled)
        case "markdown": MarkdownAnswerView(text: context.text(node["value"] ?? node["text"]))
        case "math": MathBlockView(latex: context.text(node["latex"] ?? node["value"]))
        case "code": CodeBlockView(language: context.text(node["language"]), code: context.text(node["code"] ?? node["value"]))
        case "icon":
            Image(systemName: context.text(node["name"])).font(.system(size: CGFloat(context.number(node["size"]) ?? 20))).foregroundStyle(tone(node["tone"] ?? node["color"]))
        case "image":
            if let url = URL(string: context.text(node["url"])), url.scheme == "https" { AnswerImage(alt: context.text(node["alt"]), url: url) }
        case "badge", "tag":
            Text(context.text(node["text"] ?? node["value"])).font(.caption.weight(.semibold)).foregroundStyle(tone(node["tone"]))
                .padding(.horizontal, 8).padding(.vertical, 3).background(tone(node["tone"]).opacity(0.14), in: Capsule())
        case "metric", "stat":
            VStack(alignment: .leading, spacing: 2) {
                Text(context.text(node["label"])).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(context.text(node["value"])).font(.title2.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
                    if let unit = node["unit"] { Text(context.text(unit)).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let delta = node["delta"] { Text(context.text(delta)).font(.caption.weight(.medium)).foregroundStyle(tone(node["tone"])) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy, value: context.text(node["value"]))
        case "progress":
            VStack(alignment: .leading, spacing: 4) {
                if let label = node["label"] { Text(context.text(label)).font(.subheadline) }
                ProgressView(value: min(1, max(0, context.number(node["value"]) ?? 0))).tint(tone(node["tone"] ?? .string("accent")))
            }
        case "keyvalue", "properties":
            VStack(spacing: 0) {
                ForEach(Array((node["items"]?.array ?? []).prefix(40).enumerated()), id: \.offset) { index, item in
                    if index > 0 { Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(context.text(item["label"])).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(context.text(item["value"])).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
                    }.padding(.vertical, 8)
                }
            }
        case "list":
            VStack(spacing: 0) {
                ForEach(Array((node["items"]?.array ?? []).prefix(60).enumerated()), id: \.offset) { index, item in
                    if index > 0 { Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5).padding(.leading, item["icon"] == nil ? 0 : 34) }
                    listRow(item)
                }
            }
        case "steps", "timeline":
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array((node["items"]?.array ?? []).prefix(30).enumerated()), id: \.offset) { index, item in
                    let done = context.value(item["done"]).truthy
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle().fill(done ? Color.accentColor : MarkdownStyle.inlineCode).frame(width: 22, height: 22)
                            if done { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                            else { Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.text(item["title"])).font(.subheadline.weight(.medium))
                            if let d = item["detail"] { Text(context.text(d)).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        case "table":
            let columns = (node["columns"]?.array ?? []).map { context.text($0) }
            let rows = (node["rows"]?.array ?? []).prefix(80).map { ($0.array ?? []).map { context.text($0) } }
            TableBlockView(header: columns, alignments: columns.map { _ in .leading }, rows: Array(rows), bodySize: 17, color: .label)
        case "chart": GenUIChart(node: node, context: context)
        case "canvas": GenUICanvas(node: node, context: context)

        // Inputs
        case "button": button
        case "chips", "choices", "select":
            GenUIChips(node: node, context: context)
        case "toggle":
            let key = context.text(node["bind"])
            Toggle(context.text(node["label"]), isOn: Binding(get: { context.state[key]?.truthy ?? false }, set: { store.set(context.id, key, .bool($0), initial: context.initial) }))
                .disabled(context.live)
        case "slider":
            let key = context.text(node["bind"])
            let lo = context.number(node["min"]) ?? 0, hi = max(lo + 0.0001, context.number(node["max"]) ?? 100)
            let step = context.number(node["step"]) ?? 0
            let current = min(hi, max(lo, context.state[key]?.number ?? lo))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.text(node["label"])).font(.subheadline)
                    Spacer()
                    Text(node["display"].map { context.text($0) } ?? UIValue.format(current)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Group {
                    if step > 0 {
                        Slider(value: Binding(get: { current }, set: { store.set(context.id, key, .number($0), initial: context.initial) }), in: lo...hi, step: step)
                    } else {
                        Slider(value: Binding(get: { current }, set: { store.set(context.id, key, .number($0), initial: context.initial) }), in: lo...hi)
                    }
                }
                .accessibilityLabel(context.text(node["label"])).accessibilityValue(UIValue.format(current))
            }
            .disabled(context.live)
        case "stepper":
            let key = context.text(node["bind"])
            let lo = context.number(node["min"]) ?? 0, hi = context.number(node["max"]) ?? 100, step = context.number(node["step"]) ?? 1
            let current = context.state[key]?.number ?? lo
            Stepper(value: Binding(get: { current }, set: { store.set(context.id, key, .number(min(hi, max(lo, $0))), initial: context.initial) }), in: lo...hi, step: step) {
                HStack { Text(context.text(node["label"])); Spacer(); Text(UIValue.format(current)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .disabled(context.live)
        case "textfield", "input":
            let key = context.text(node["bind"])
            TextField(context.text(node["placeholder"] ?? node["label"]), text: Binding(get: { context.state[key]?.string ?? "" },
                                                                                          set: { store.set(context.id, key, .string(String($0.prefix(500))), initial: context.initial) }),
                      axis: context.value(node["multiline"]).truthy ? .vertical : .horizontal)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(context.live)
        case "picker", "segmented":
            let key = context.text(node["bind"])
            let options = GenUIChips.options(node, context)
            let picker = Picker(context.text(node["label"]), selection: Binding(get: { context.state[key]?.string ?? options.first?.value ?? "" },
                                                                  set: { store.set(context.id, key, .string($0), initial: context.initial) })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            Group {
                if type == "segmented" || context.text(node["style"]) == "segmented" { picker.pickerStyle(.segmented) }
                else { HStack { Text(context.text(node["label"])).font(.subheadline); Spacer(); picker.pickerStyle(.menu) } }
            }
            .disabled(context.live)
        default:
            // Unknown component: render its children if any, otherwise nothing (never a crash, never raw JSON in prose).
            if !children.isEmpty { VStack(alignment: .leading, spacing: spacing) { childList(children) } }
        }
    }

    private func listRow(_ item: UIValue) -> some View {
        HStack(spacing: 10) {
            if let icon = item["icon"] {
                Image(systemName: context.text(icon)).frame(width: 24).foregroundStyle(tone(item["tone"] ?? .string("accent")))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(context.text(item["title"])).font(.subheadline.weight(.medium))
                if let s = item["subtitle"] { Text(context.text(s)).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let t = item["trailing"] { Text(context.text(t)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 9).contentShape(Rectangle())
        .onTapGesture { if let action = item["action"] { perform(action, actionId: "list:" + context.text(item["title"])) } }
    }

    @ViewBuilder private var button: some View {
        let label = context.text(node["label"] ?? node["text"])
        let actionId = node["id"]?.string ?? "button:" + label
        let action = node["action"] ?? node["onTap"] ?? .null
        let leaves = Self.leavesInterface(action)
        let done = leaves && store.isDone(context.id, actionId)
        let style = context.text(node["style"])
        let content = Label { Text(done ? (node["doneLabel"].map { context.text($0) } ?? "已发送") : label) } icon: {
            if done { Image(systemName: "checkmark") } else if let icon = node["icon"] { Image(systemName: context.text(icon)) }
        }
        .font(.subheadline.weight(.semibold)).frame(maxWidth: context.value(node["fullWidth"]).truthy ? .infinity : nil)
        Group {
            switch style {
            case "primary", "prominent": Button { perform(action, actionId: actionId) } label: { content }.buttonStyle(.borderedProminent)
            case "plain", "link": Button { perform(action, actionId: actionId) } label: { content }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            case "destructive": Button(role: .destructive) { perform(action, actionId: actionId) } label: { content }.buttonStyle(.bordered)
            default: Button { perform(action, actionId: actionId) } label: { content }.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .disabled(context.live || done || submittingAction || (leaves && handler?.canSend != true))
        .accessibilityIdentifier("genui.button.\(label)")
    }

    static func leavesInterface(_ action: UIValue) -> Bool {
        if let list = action.array { return list.contains { leavesInterface($0) } }
        let kind = action["type"]?.string ?? (action["send"] != nil ? "send" : action["tool"] != nil ? "tool" : "")
        return kind == "send" || kind == "tool"
    }

    /// Runs an action list. Local actions change this interface's state; `send`/`tool` leave the interface as a visible user
    /// message in the conversation and are recorded so they are not offered again after a relaunch.
    private func perform(_ action: UIValue, actionId: String) {
        if let list = action.array { for a in list.prefix(10) { perform(a, actionId: actionId) }; return }
        guard case .object(let o) = action else { return }
        let kind = o["type"]?.string ?? (o["send"] != nil ? "send" : o["set"] != nil ? "set" : o["tool"] != nil ? "tool" : o["toggle"] != nil ? "toggle" : o["open"] != nil ? "open" : "")
        switch kind {
        case "set":
            if case .object(let pairs)? = o["set"] {
                for (k, v) in pairs { store.set(context.id, k, context.value(v), initial: context.initial) }
            } else if let key = o["key"]?.string {
                store.set(context.id, key, context.value(o["value"]), initial: context.initial)
            }
        case "toggle":
            let key = o["key"]?.string ?? o["toggle"]?.string ?? ""
            store.set(context.id, key, .bool(!(context.state[key]?.truthy ?? false)), initial: context.initial)
        case "send":
            let text = context.text(o["text"] ?? o["send"] ?? o["message"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            submit(String(text.prefix(2000)), actionId: actionId)
        case "tool":
            // Generated UI never calls a tool itself: it asks the agent, in the open, and the agent's normal permission and
            // approval rules decide. The model wrote this request, so it reads as the person's choice in this interface.
            let name = context.text(o["tool"] ?? o["name"])
            var args = ""
            if case .object(let a)? = o["arguments"] {
                args = a.sorted { $0.key < $1.key }.map { "\($0.key)=\(context.value($0.value).string)" }.joined(separator: "，")
            }
            let label = context.text(o["label"])
            submit(label.isEmpty ? "请执行 \(name)\(args.isEmpty ? "" : "（\(args)）")" : label, actionId: actionId)
        case "open":
            if let url = URL(string: context.text(o["url"] ?? o["open"])), url.scheme == "https" { openURL(url) }
        case "copy":
            UIPasteboard.general.string = context.text(o["text"] ?? o["copy"]); AppFeedback.medium()
        case "reset":
            store.reset(context.id)
        default: break
        }
    }

    // CONTEXT MEMORY
    // Updated: 2026-11-01
    // Status: inferred
    // Why: A remote task submission can fail after the computer has already accepted it.
    // Debug Goal: Retry one card action under the same request identity and mark it sent only after acknowledgement.
    // Search Tags: generated ui remote action idempotency retry acknowledgement
    // Invariants:
    // - The identity includes the remote task namespace, interface id and action id.
    // - An unavailable or failed handler leaves the action available to retry.
    // Failure Modes:
    // - Marking an action complete before a network acknowledgement loses the user's request.
    // - Generating a new request id after a timeout can duplicate a remote task.
    private func submit(_ text: String, actionId: String) {
        guard let handler, handler.canSend, !submittingAction, !store.isDone(context.id, actionId) else { return }
        let material = Data((context.id + "\u{0}" + actionId).utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        let key = "genui-" + digest
        submittingAction = true
        Task { @MainActor in
            if await handler.send(text, key) {
                store.markDone(context.id, actionId)
                AppFeedback.medium()
            }
            submittingAction = false
        }
    }

    // MARK: style helpers

    private var horizontalAlign: HorizontalAlignment {
        switch context.text(node["align"]) { case "center": .center; case "trailing", "end", "right": .trailing; default: .leading }
    }
    private var frameAlign: Alignment {
        switch context.text(node["align"]) { case "center": .center; case "trailing", "end", "right": .trailing; default: .leading }
    }
    private var textAlign: TextAlignment {
        switch context.text(node["align"]) { case "center": .center; case "trailing", "end", "right": .trailing; default: .leading }
    }
    private var verticalAlign: VerticalAlignment {
        switch context.text(node["align"]) { case "top": .top; case "bottom": .bottom; default: .center }
    }
    private func font(_ v: UIValue?) -> Font {
        switch context.text(v) {
        case "largeTitle": .largeTitle.weight(.bold)
        case "title": .title2.weight(.semibold)
        case "title3": .title3.weight(.semibold)
        case "headline": .headline
        case "subheadline": .subheadline
        case "callout": .callout
        case "footnote": .footnote
        case "caption": .caption
        case "mono", "monospaced": .body.monospaced()
        default: .body
        }
    }
    private func weight(_ v: UIValue?) -> Font.Weight? {
        switch context.text(v) { case "bold": .bold; case "semibold": .semibold; case "medium": .medium; case "light": .light; default: nil }
    }
    func tone(_ v: UIValue?) -> Color { GenUITone.color(context.text(v)) }
}

enum GenUITone {
    static func color(_ name: String) -> Color {
        switch name {
        case "secondary", "muted": .secondary
        case "accent", "blue", "info": .accentColor
        case "success", "green", "positive": .green
        case "warning", "orange": .orange
        case "danger", "red", "negative", "error": .red
        case "purple": .purple
        case "pink": .pink
        case "teal", "cyan": .teal
        case "yellow": .yellow
        case "indigo": .indigo
        default: .primary
        }
    }
}

private struct GenUIAccessibility: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}


/// Selection capsules bound to a state key (single or multiple).
struct GenUIChips: View {
    let node: UIValue
    let context: GenUIContext
    @State private var store = GenUIStore.shared

    struct Option { let label: String; let value: String; let icon: String? }
    static func options(_ node: UIValue, _ context: GenUIContext) -> [Option] {
        (context.value(node["options"]).array ?? node["options"]?.array ?? []).prefix(40).map { o in
            if case .object = o { return Option(label: context.text(o["label"] ?? o["value"]), value: context.text(o["value"] ?? o["label"]), icon: o["icon"].map { context.text($0) }) }
            return Option(label: o.string, value: o.string, icon: nil)
        }
    }

    var body: some View {
        let key = context.text(node["bind"])
        let multiple = context.value(node["multiple"]).truthy
        let current = context.state[key]
        let selected: Set<String> = multiple ? Set((current?.array ?? []).map(\.string)) : (current.map { [$0.string] } ?? [])
        VStack(alignment: .leading, spacing: 8) {
            if let label = node["label"] { Text(context.text(label)).font(.subheadline).foregroundStyle(.secondary) }
            GenUIFlow(spacing: 8) {
                ForEach(Self.options(node, context), id: \.value) { option in
                    let on = selected.contains(option.value)
                    Button {
                        if multiple {
                            var next = selected
                            if on { next.remove(option.value) } else { next.insert(option.value) }
                            store.set(context.id, key, .array(next.sorted().map(UIValue.string)), initial: context.initial)
                        } else {
                            store.set(context.id, key, .string(option.value), initial: context.initial)
                        }
                    } label: {
                        Label { Text(option.label) } icon: { if let icon = option.icon { Image(systemName: icon) } }
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .padding(.horizontal, 13).frame(minHeight: 34)
                            .foregroundStyle(on ? Color.white : .primary)
                            .background(on ? Color.accentColor : MarkdownStyle.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(on ? Color.clear : MarkdownStyle.hairline, lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain).disabled(context.live)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

/// Wrapping layout for capsules.
struct GenUIFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(width, maxX), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// Bar / line / area / point / pie charts from `data: [{x, y, series?}]` (values may be bindings).
struct GenUIChart: View {
    let node: UIValue
    let context: GenUIContext

    struct Point: Identifiable { let id: Int; let x: String; let y: Double; let series: String }

    var body: some View {
        let points: [Point] = (context.value(node["data"]).array ?? node["data"]?.array ?? []).prefix(200).enumerated().compactMap { i, d in
            guard let y = context.number(d["y"] ?? d["value"]) else { return nil }
            return Point(id: i, x: context.text(d["x"] ?? d["label"]), y: y, series: context.text(d["series"]))
        }
        let kind = context.text(node["kind"] ?? node["mark"])
        VStack(alignment: .leading, spacing: 6) {
            if let title = node["title"] { Text(context.text(title)).font(.subheadline.weight(.semibold)) }
            Chart(points) { p in
                switch kind {
                case "line":
                    LineMark(x: .value(context.text(node["xLabel"]), p.x), y: .value(context.text(node["yLabel"]), p.y))
                        .foregroundStyle(by: .value("系列", p.series.isEmpty ? " " : p.series)).interpolationMethod(.catmullRom)
                    PointMark(x: .value(context.text(node["xLabel"]), p.x), y: .value(context.text(node["yLabel"]), p.y))
                        .foregroundStyle(by: .value("系列", p.series.isEmpty ? " " : p.series))
                case "area":
                    AreaMark(x: .value(context.text(node["xLabel"]), p.x), y: .value(context.text(node["yLabel"]), p.y))
                        .foregroundStyle(by: .value("系列", p.series.isEmpty ? " " : p.series)).opacity(0.6)
                case "point", "scatter":
                    PointMark(x: .value(context.text(node["xLabel"]), p.x), y: .value(context.text(node["yLabel"]), p.y))
                        .foregroundStyle(by: .value("系列", p.series.isEmpty ? " " : p.series))
                case "pie", "donut":
                    SectorMark(angle: .value("值", p.y), innerRadius: .ratio(kind == "donut" ? 0.55 : 0), angularInset: 1.5)
                        .foregroundStyle(by: .value("类别", p.x)).cornerRadius(3)
                default:
                    BarMark(x: .value(context.text(node["xLabel"]), p.x), y: .value(context.text(node["yLabel"]), p.y))
                        .foregroundStyle(by: .value("系列", p.series.isEmpty ? " " : p.series)).cornerRadius(4)
                }
            }
            .chartLegend(Set(points.map(\.series)).count > 1 || kind == "pie" || kind == "donut" ? .visible : .hidden)
            .frame(height: CGFloat(context.number(node["height"]) ?? 200))
            .animation(.smooth, value: points.map(\.y))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node["title"].map { context.text($0) } ?? "图表")
    }
}

/// A small sandboxed vector canvas for interactive explanations: shapes in a fixed coordinate space, any number of which may be
/// bound to state (a slider moving a point, a bar growing with a value). No scripting: geometry is data and expressions.
struct GenUICanvas: View {
    let node: UIValue
    let context: GenUIContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let w = max(10, context.number(node["width"]) ?? 300), h = max(10, context.number(node["height"]) ?? 180)
        let shapes = Array((node["shapes"]?.array ?? []).prefix(200))
        Canvas { ctx, size in
            let sx = size.width / w, sy = size.height / h
            for shape in shapes {
                if let visible = shape["visible"], !context.value(visible).truthy { continue }
                let color = GenUITone.color(context.text(shape["color"] ?? .string("accent")))
                let lineWidth = CGFloat(context.number(shape["lineWidth"]) ?? 2)
                func pt(_ x: UIValue?, _ y: UIValue?) -> CGPoint { CGPoint(x: (context.number(x) ?? 0) * sx, y: (context.number(y) ?? 0) * sy) }
                switch context.text(shape["kind"]) {
                case "circle":
                    let c = pt(shape["x"], shape["y"]), r = (context.number(shape["r"]) ?? 6) * min(sx, sy)
                    let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    if context.value(shape["stroke"]).truthy { ctx.stroke(path, with: .color(color), lineWidth: lineWidth) } else { ctx.fill(path, with: .color(color)) }
                case "rect":
                    let o = pt(shape["x"], shape["y"])
                    let rect = CGRect(x: o.x, y: o.y, width: (context.number(shape["w"]) ?? 10) * sx, height: (context.number(shape["h"]) ?? 10) * sy)
                    let path = Path(roundedRect: rect, cornerRadius: CGFloat(context.number(shape["radius"]) ?? 0))
                    if context.value(shape["stroke"]).truthy { ctx.stroke(path, with: .color(color), lineWidth: lineWidth) } else { ctx.fill(path, with: .color(color.opacity(context.number(shape["opacity"]) ?? 1))) }
                case "line", "arrow":
                    let a = pt(shape["x1"], shape["y1"]), b = pt(shape["x2"], shape["y2"])
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    if context.text(shape["kind"]) == "arrow" {
                        let angle = atan2(b.y - a.y, b.x - a.x), head: CGFloat = 8
                        path.move(to: b); path.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
                        path.move(to: b); path.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: context.value(shape["dashed"]).truthy ? [5, 4] : []))
                case "polyline", "plot":
                    // Either explicit points or a function y = f(x) sampled over [from, to].
                    var path = Path()
                    if let expr = shape["fn"]?.string {
                        let from = context.number(shape["from"]) ?? 0, to = context.number(shape["to"]) ?? w
                        let scale = context.number(shape["scaleY"]) ?? 1, originY = context.number(shape["originY"]) ?? h / 2
                        let originX = context.number(shape["originX"]) ?? 0, scaleX = context.number(shape["scaleX"]) ?? 1
                        for k in 0...120 {
                            let x = from + (to - from) * Double(k) / 120
                            var s = context.state; s["x"] = .number(x)
                            guard let y = UIExpression.evaluate(expr, state: s).number, y.isFinite else { continue }
                            let p = CGPoint(x: (originX + x * scaleX) * sx, y: (originY - y * scale) * sy)
                            if path.isEmpty { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    } else {
                        for (k, p) in (shape["points"]?.array ?? []).prefix(400).enumerated() {
                            let q = pt(p.array?.first ?? p["x"], p.array?.dropFirst().first ?? p["y"])
                            if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
                        }
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                case "text":
                    let p = pt(shape["x"], shape["y"])
                    ctx.draw(Text(context.text(shape["text"])).font(.system(size: CGFloat(context.number(shape["size"]) ?? 13))).foregroundStyle(color), at: p)
                default: continue
                }
            }
        }
        .aspectRatio(w / h, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement().accessibilityLabel(context.text(node["accessibilityLabel"] ?? node["title"] ?? .string("示意图")))
    }
}
