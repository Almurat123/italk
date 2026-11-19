import Foundation

public enum MemoryStoreError: Error, Equatable, Sendable {
    case invalid
    /// Looks like a password, key, card or ID number: never stored.
    case refusedSecret
    case notFound
    case memoryDisabled
}

/// A remembered fact's deletion. Kept so a synced copy that comes back later cannot resurrect it.
public struct MemoryTombstone: Codable, Sendable, Equatable {
    public var id: UUID
    public var deletedAt: Date
    public var revision: Int
    public init(id: UUID, deletedAt: Date, revision: Int) { self.id = id; self.deletedAt = deletedAt; self.revision = revision }
}

/// Personal memory, separate from conversation transcripts and from context compression: short facts the person can read,
/// edit and delete. Deleting removes the text immediately and leaves only an id-and-time tombstone (so sync can propagate it).
public actor MemoryStore {
    struct File: Codable {
        var items: [MemoryItem] = []
        var tombstones: [MemoryTombstone] = []
        var settings = MemorySettings()
    }

    public enum AddOutcome: Sendable, Equatable { case added, merged }
    public static let maxLength = 500
    static let tombstoneRetention: TimeInterval = 90 * 86_400

    private var file = File()
    private let url: URL?
    private var listeners: [UUID: @Sendable () -> Void] = [:]

    /// `url == nil` keeps everything in memory (tests, previews).
    public init(url: URL? = nil) throws {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) { file = try AgentCoding.decoder().decode(File.self, from: data) }
    }

    // MARK: Reading

    public func settings() -> MemorySettings { file.settings }
    public func item(_ id: UUID) -> MemoryItem? { file.items.first { $0.id == id } }
    public func itemForSlot(_ slot: String) -> MemoryItem? { file.items.first { $0.slot == slot } }
    public func tombstones() -> [MemoryTombstone] { file.tombstones }
    public var count: Int { file.items.count }

    /// Pinned first, then most recently changed.
    public func all() -> [MemoryItem] {
        file.items.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    /// Lexical relevance (Chinese bigrams + English words) with a small recency and pinned boost. `limit` caps the result.
    public func search(_ query: String, limit: Int = 10, includeSensitive: Bool = false) -> [MemoryItem] {
        let pool = file.items.filter { includeSensitive || !$0.sensitive }
        let q = Self.tokens(query)
        guard !q.isEmpty else { return Array(pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)) }
        let now = Date.now
        let scored: [(MemoryItem, Double)] = pool.compactMap { m in
            let t = Self.tokens(m.text)
            let overlap = Double(q.intersection(t).count)
            guard overlap > 0 else { return nil }
            let age = max(0, now.timeIntervalSince(m.updatedAt)) / 86_400
            return (m, overlap / Double(q.count).squareRoot() / Double(max(t.count, 1)).squareRoot() + (m.pinned ? 0.3 : 0) + 0.15 / (1 + age / 30))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// What goes into a model's context for the next turn: standing instructions and pinned items first, then the most relevant
    /// ones, within `characterBudget`. Nothing is returned when memory is switched off.
    public func context(for text: String, characterBudget: Int, includeSensitive: Bool = false) -> [MemoryItem] {
        guard file.settings.enabled else { return [] }
        var chosen: [MemoryItem] = [], used = 0
        func take(_ m: MemoryItem) {
            guard !chosen.contains(where: { $0.id == m.id }), used + m.text.count + 4 <= characterBudget else { return }
            chosen.append(m); used += m.text.count + 4
        }
        let pool = file.items.filter { includeSensitive || !$0.sensitive }
        for m in pool.filter({ $0.pinned || $0.kind == .instruction }).sorted(by: { $0.updatedAt > $1.updatedAt }) { take(m) }
        for m in search(text, limit: 12, includeSensitive: includeSensitive) { take(m) }
        for m in pool.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(6) { take(m) }
        return chosen
    }

    // MARK: Writing

    /// Adds a memory, or merges it into a near-identical one (same fact stated again). Throws `.refusedSecret` for secrets.
    @discardableResult
    public func add(text raw: String, kind: MemoryKind, source: MemorySource, sensitive: Bool = false, pinned: Bool = false,
                    respectSwitch: Bool = true, slot: String? = nil, now: Date = .now) throws -> (item: MemoryItem, outcome: AddOutcome) {
        if respectSwitch, !file.settings.enabled { throw MemoryStoreError.memoryDisabled }
        let text = try Self.clean(raw)
        if let i = file.items.firstIndex(where: { Self.similar($0.text, text) }) {
            file.items[i].text = text.count >= file.items[i].text.count ? text : file.items[i].text
            file.items[i].updatedAt = now; file.items[i].revision += 1
            file.items[i].sensitive = file.items[i].sensitive || sensitive
            if pinned { file.items[i].pinned = true }
            try save(); return (file.items[i], .merged)
        }
        let item = MemoryItem(text: text, kind: kind, source: source, createdAt: now, updatedAt: now, sensitive: sensitive, pinned: pinned, slot: slot)
        file.items.append(item)
        file.tombstones.removeAll { $0.id == item.id }
        try save(); return (item, .added)
    }

    @discardableResult
    public func update(_ id: UUID, text: String? = nil, kind: MemoryKind? = nil, pinned: Bool? = nil, sensitive: Bool? = nil,
                       expectedRevision: Int? = nil, now: Date = .now) throws -> MemoryItem {
        guard let i = file.items.firstIndex(where: { $0.id == id }) else { throw MemoryStoreError.notFound }
        if let expectedRevision, file.items[i].revision != expectedRevision { throw MemoryStoreError.invalid }
        if let text { file.items[i].text = try Self.clean(text) }
        if let kind { file.items[i].kind = kind }
        if let pinned { file.items[i].pinned = pinned }
        if let sensitive { file.items[i].sensitive = sensitive }
        file.items[i].updatedAt = now; file.items[i].revision += 1
        try save(); return file.items[i]
    }

    @discardableResult
    public func delete(_ id: UUID, now: Date = .now) throws -> Bool {
        guard let i = file.items.firstIndex(where: { $0.id == id }) else { return false }
        let gone = file.items.remove(at: i)
        file.tombstones.append(MemoryTombstone(id: id, deletedAt: now, revision: gone.revision + 1))
        try save(); return true
    }

    public func deleteAll(now: Date = .now) throws {
        for m in file.items { file.tombstones.append(MemoryTombstone(id: m.id, deletedAt: now, revision: m.revision + 1)) }
        file.items.removeAll()
        try save()
    }

    public func setSettings(_ s: MemorySettings) throws { file.settings = s; try save() }

    /// Everything a sync copy needs: the items and the deletions (not the per-device settings).
    public func export() -> (items: [MemoryItem], tombstones: [MemoryTombstone]) { (file.items, file.tombstones) }

    /// After devices were merged, two of them may have learned different values for the same thing (each device saw a different "住在…").
    /// The most recently changed one stays; the others are deleted (with tombstones, so every device agrees). Returns how many were removed.
    @discardableResult
    public func resolveSlotConflicts(now: Date = .now) throws -> Int {
        var removed = 0
        for slot in Set(file.items.compactMap(\.slot)) {
            let group = file.items.filter { $0.slot == slot }
            guard group.count > 1, let keep = group.max(by: { ($0.updatedAt, $0.revision, $0.id.uuidString) < ($1.updatedAt, $1.revision, $1.id.uuidString) }) else { continue }
            for loser in group where loser.id != keep.id {
                file.items.removeAll { $0.id == loser.id }
                file.tombstones.append(MemoryTombstone(id: loser.id, deletedAt: now, revision: loser.revision + 1)); removed += 1
            }
        }
        if removed > 0 { try save() }
        return removed
    }

    /// Folds in a copy from another device: the higher revision wins; a deletion wins over an edit made before it.
    public func merge(items: [MemoryItem], tombstones incoming: [MemoryTombstone]) throws {
        let itemsBefore = file.items, tombstonesBefore = file.tombstones
        for t in incoming {
            if let i = file.items.firstIndex(where: { $0.id == t.id }), file.items[i].updatedAt <= t.deletedAt { file.items.remove(at: i) }
            if !file.tombstones.contains(where: { $0.id == t.id && $0.deletedAt >= t.deletedAt }) {
                file.tombstones.removeAll { $0.id == t.id }; file.tombstones.append(t)
            }
        }
        for m in items {
            if let t = file.tombstones.first(where: { $0.id == m.id }), t.deletedAt >= m.updatedAt { continue }
            if let i = file.items.firstIndex(where: { $0.id == m.id }) {
                if (m.revision, m.updatedAt) > (file.items[i].revision, file.items[i].updatedAt) { file.items[i] = m }
            } else { file.items.append(m) }
        }
        // Only a real change is saved and announced: a sync that merges an unchanged copy must not wake the sync listener again.
        if file.items != itemsBefore || file.tombstones != tombstonesBefore { try save() }
    }

    /// Imports records from before this store existed (once). Existing ids are left alone.
    public func importLegacy(_ legacy: [(id: UUID, text: String, sensitive: Bool, created: Date, updated: Date, revision: Int)]) throws {
        for r in legacy where !file.items.contains(where: { $0.id == r.id }) && !file.tombstones.contains(where: { $0.id == r.id }) {
            guard let text = try? Self.clean(r.text) else { continue }
            file.items.append(MemoryItem(id: r.id, text: text, kind: .fact, source: .user, createdAt: r.created, updatedAt: r.updated,
                                         sensitive: r.sensitive, pinned: false, revision: r.revision))
        }
        try save()
    }

    /// Calls `body` after every change (UI refresh). Returns a token for `removeListener`.
    @discardableResult public func addListener(_ body: @escaping @Sendable () -> Void) -> UUID { let id = UUID(); listeners[id] = body; return id }
    public func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: Internals

    private func save() throws {
        let cutoff = Date.now.addingTimeInterval(-Self.tombstoneRetention)
        file.tombstones.removeAll { $0.deletedAt < cutoff }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try AgentCoding.encoder().encode(file)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }
        for l in listeners.values { l() }
    }

    static func clean(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxLength else { throw MemoryStoreError.invalid }
        if SecretScanner.looksSecret(t) { throw MemoryStoreError.refusedSecret }
        return t
    }

    /// Mixed Chinese/English tokens: lowercase ASCII words and CJK bigrams (plus single characters for very short queries).
    static func tokens(_ s: String) -> Set<String> {
        var out = Set<String>(), word = "", cjk: [Character] = []
        func flushWord() { if word.count > 1 { out.insert(word) }; word = "" }
        func flushCJK() {
            if cjk.count == 1 { out.insert(String(cjk[0])) }
            if cjk.count >= 2 { for i in 0..<(cjk.count - 1) { out.insert(String(cjk[i...i + 1])) } }
            cjk = []
        }
        for ch in s.lowercased() {
            if ch.isCJK { flushWord(); cjk.append(ch) }
            else if ch.isLetter || ch.isNumber { flushCJK(); word.append(ch) }
            else { flushWord(); flushCJK() }
        }
        flushWord(); flushCJK()
        return out
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation } }
        let na = norm(a), nb = norm(b)
        if na == nb { return true }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return jaccard >= 0.8
    }
}

private extension Character {
    var isCJK: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }
}

/// Catches text that must never become a memory or a log line: card numbers, ID numbers, keys, passwords.
public enum SecretScanner {
    public static func looksSecret(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        // A run of 13-19 digits that passes the Luhn check is a card number; an 18-character mainland ID number ends in a digit or X.
        for run in digitRuns(in: s) where (13...19).contains(run.count) && luhn(run) { return true }
        if digits.count >= 17, s.range(of: #"\b\d{17}[0-9Xx]\b"#, options: .regularExpression) != nil { return true }
        let patterns = [#"sk-[A-Za-z0-9_\-]{16,}"#, #"AKIA[0-9A-Z]{16}"#, #"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"#, #"[A-Fa-f0-9]{40,}"#, #"[A-Za-z0-9+/_\-]{40,}={0,2}"#,
                        #"(?i)(password|passwd|pwd|密码|口令)\s*(is|为|是|[:：=])\s*\S{4,}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    private static func digitRuns(in s: String) -> [String] {
        var runs: [String] = [], cur = ""
        for ch in s {
            if ch.isNumber { cur.append(ch) } else if (ch == " " || ch == "-") && !cur.isEmpty { continue } else { if !cur.isEmpty { runs.append(cur) }; cur = "" }
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0, alt = false
        for ch in digits.reversed() {
            guard var d = ch.wholeNumberValue else { return false }
            if alt { d *= 2; if d > 9 { d -= 9 } }
            sum += d; alt.toggle()
        }
        return sum % 10 == 0
    }
}
