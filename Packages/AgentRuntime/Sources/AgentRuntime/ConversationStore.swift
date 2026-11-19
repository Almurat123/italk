import Foundation
import CryptoKit

/// Local conversation database (SQLite). The single source of truth for conversation history: the UI list, the chat view and
/// the ContextManager all read from here. Separate from long-term memory, which keeps its own store and consent.
/// Context compaction writes summaries next to messages; it never deletes or rewrites messages.
public actor ConversationStore {
    public static let schemaVersion = 1
    /// Soft-deleted conversations are restorable for this long, then purged with their attachments.
    public static let purgeAfter: TimeInterval = 30 * 86_400

    private let db: SQLiteDB
    public nonisolated let attachmentsRoot: URL
    private let now: @Sendable () -> Date
    private var fts = false

    /// `directory == nil` gives an in-memory store (history saving turned off): nothing touches disk.
    public init(directory: URL?, now: @escaping @Sendable () -> Date = { .now }) throws {
        self.now = now
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var d = directory; var v = URLResourceValues(); v.isExcludedFromBackup = true; try? d.setResourceValues(v)
            db = try SQLiteDB(path: directory.appendingPathComponent("conversations.sqlite").path)
            attachmentsRoot = directory.appendingPathComponent("attachments", isDirectory: true)
        } else {
            db = try SQLiteDB(path: ":memory:")
            attachmentsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("italk-ephemeral-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conversations (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, title_source TEXT NOT NULL, created_at REAL NOT NULL, last_activity_at REAL NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, deleted_at REAL, last_model_id TEXT);
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
          role TEXT NOT NULL, parts TEXT NOT NULL, plain TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
          run_id TEXT, model_id TEXT, input_mode TEXT, ephemeral INTEGER NOT NULL DEFAULT 0, UNIQUE(conversation_id, seq));
        CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation_id, seq);
        CREATE TABLE IF NOT EXISTS attachments (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, kind TEXT NOT NULL,
          path TEXT NOT NULL, mime TEXT NOT NULL, bytes INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
          sha256 TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS summaries (
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, version INTEGER NOT NULL,
          through_seq INTEGER NOT NULL, body TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(conversation_id, version));
        CREATE TABLE IF NOT EXISTS runs (
          run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, state TEXT NOT NULL, updated_at REAL NOT NULL);
        INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '\(Self.schemaVersion)');
        """)
        // Full-text index (trigram handles Chinese). If this SQLite build lacks it, search falls back to LIKE; nothing else changes.
        do { try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(plain, message_id UNINDEXED, conversation_id UNINDEXED, tokenize='trigram');"); fts = true }
        catch { fts = false }
        // Session-only messages (e.g. health-related turns when health history is not allowed) never survive a relaunch.
        try db.exec("DELETE FROM messages WHERE ephemeral = 1; DELETE FROM conversations WHERE id NOT IN (SELECT conversation_id FROM messages) AND title = '新对话';")
    }

    // MARK: Conversations

    @discardableResult
    public func createConversation(id: UUID = UUID(), title: String = "新对话") throws -> Conversation {
        let t = now().timeIntervalSince1970
        try db.run("INSERT INTO conversations(id, title, title_source, created_at, last_activity_at) VALUES(?,?,?,?,?)",
                   [.text(id.uuidString), .text(title), .text("automatic"), .real(t), .real(t)])
        return try conversation(id)!
    }

    public func conversation(_ id: UUID) throws -> Conversation? {
        try listRows(where: "c.id = ?", [.text(id.uuidString)]).first
    }

    /// Sidebar list. Active = not archived, not deleted. Pinned first, then most recent activity.
    public func list(_ filter: ConversationFilter = .active, limit: Int = 200) throws -> [Conversation] {
        switch filter {
        case .active: try listRows(where: "c.deleted_at IS NULL AND c.archived = 0", [], limit: limit)
        case .archived: try listRows(where: "c.deleted_at IS NULL AND c.archived = 1", [], limit: limit)
        case .deleted: try listRows(where: "c.deleted_at IS NOT NULL", [], limit: limit)
        }
    }

    private func listRows(where clause: String, _ args: [SQLiteDB.Value], limit: Int = 1) throws -> [Conversation] {
        let rows = try db.query("""
        SELECT c.*, (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS n,
          (SELECT plain FROM messages m WHERE m.conversation_id = c.id AND m.status = 'final' ORDER BY seq DESC LIMIT 1) AS preview,
          (SELECT COUNT(*) FROM runs r WHERE r.conversation_id = c.id AND r.state NOT IN ('completed','failed','cancelled','expired')) AS open_runs
        FROM conversations c WHERE \(clause) ORDER BY c.pinned DESC, c.last_activity_at DESC LIMIT \(limit)
        """, args)
        return rows.map { r in
            Conversation(id: UUID(uuidString: r.str("id")!)!, title: r.str("title") ?? "", titleSource: .init(rawValue: r.str("title_source") ?? "") ?? .automatic,
                         createdAt: r.date("created_at")!, lastActivityAt: r.date("last_activity_at")!, pinned: r.int("pinned") == 1,
                         archived: r.int("archived") == 1, deletedAt: r.date("deleted_at"), lastModelId: r.str("last_model_id"),
                         messageCount: Int(r.int("n") ?? 0), preview: String((r.str("preview") ?? "").prefix(80)), hasUnfinishedRun: (r.int("open_runs") ?? 0) > 0)
        }
    }

    public func rename(_ id: UUID, to title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try db.run("UPDATE conversations SET title = ?, title_source = 'user' WHERE id = ?", [.text(String(t.prefix(60))), .text(id.uuidString)])
    }
    public func setPinned(_ id: UUID, _ on: Bool) throws { try db.run("UPDATE conversations SET pinned = ? WHERE id = ?", [.int(on ? 1 : 0), .text(id.uuidString)]) }
    public func setArchived(_ id: UUID, _ on: Bool) throws { try db.run("UPDATE conversations SET archived = ?, pinned = CASE WHEN ? THEN 0 ELSE pinned END WHERE id = ?", [.int(on ? 1 : 0), .int(on ? 1 : 0), .text(id.uuidString)]) }
    /// Soft delete (undo with `restore`). Callers must cancel any active run first; see docs for the policy.
    public func delete(_ id: UUID) throws { try db.run("UPDATE conversations SET deleted_at = ?, pinned = 0 WHERE id = ?", [.real(now().timeIntervalSince1970), .text(id.uuidString)]) }
    public func restore(_ id: UUID) throws { try db.run("UPDATE conversations SET deleted_at = NULL WHERE id = ?", [.text(id.uuidString)]) }

    /// Permanently removes conversations deleted longer than `purgeAfter` ago (or a specific one), including attachment files.
    public func purge(olderThan cutoff: TimeInterval = ConversationStore.purgeAfter, only id: UUID? = nil) throws {
        let ids: [String]
        if let id { ids = [id.uuidString] }
        else { ids = try db.query("SELECT id FROM conversations WHERE deleted_at IS NOT NULL AND deleted_at < ?", [.real(now().timeIntervalSince1970 - cutoff)]).compactMap { $0.str("id") } }
        for cid in ids {
            try db.transaction {
                try ftsRun("DELETE FROM messages_fts WHERE conversation_id = ?", [.text(cid)])
                try db.run("DELETE FROM conversations WHERE id = ?", [.text(cid)])
            }
            try? FileManager.default.removeItem(at: attachmentsRoot.appendingPathComponent(cid))
        }
    }

    // MARK: Messages

    /// Appends a message with the next sequence number; updates activity time and the automatic title.
    /// - Parameter sessionOnly: kept for this app session only (used as context, excluded from search, removed at next launch).
    @discardableResult
    public func append(_ message: ConversationMessage, sessionOnly: Bool = false) throws -> ConversationMessage {
        var m = message
        try db.transaction {
            let next = (try db.query("SELECT COALESCE(MAX(seq), 0) + 1 AS s FROM messages WHERE conversation_id = ?", [.text(m.conversationId.uuidString)]).first?.int("s")) ?? 1
            m.seq = Int(next)
            try insert(m, ephemeral: sessionOnly)
            try touch(m.conversationId, modelId: m.modelId)
            if m.role == .user, !m.text.isEmpty, !sessionOnly {
                try db.run("UPDATE conversations SET title = ? WHERE id = ? AND title_source = 'automatic' AND title = '新对话'",
                           [.text(ConversationTitler.title(from: m.text)), .text(m.conversationId.uuidString)])
            }
        }
        return m
    }

    /// Replaces content/status of an existing message (streaming → final). Sequence never changes.
    public func update(_ message: ConversationMessage) throws {
        try db.transaction {
            let plain = message.text
            try db.run("UPDATE messages SET parts = ?, plain = ?, status = ?, model_id = ?, run_id = ? WHERE id = ?",
                       [.text(try Self.encode(message.parts)), .text(plain), .text(message.status.rawValue), message.modelId.map { .text($0) } ?? .null,
                        message.runId.map { .text($0.uuidString) } ?? .null, .text(message.id.uuidString)])
            try ftsRun("DELETE FROM messages_fts WHERE message_id = ?", [.text(message.id.uuidString)])
            let ephemeral = try db.query("SELECT ephemeral FROM messages WHERE id = ?", [.text(message.id.uuidString)]).first?.int("ephemeral") == 1
            if message.status == .final, !plain.isEmpty, !ephemeral {
                try ftsRun("INSERT INTO messages_fts(plain, message_id, conversation_id) VALUES(?,?,?)", [.text(plain), .text(message.id.uuidString), .text(message.conversationId.uuidString)])
            }
            try touch(message.conversationId, modelId: message.modelId)
        }
    }

    private func insert(_ m: ConversationMessage, ephemeral: Bool) throws {
        try db.run("""
        INSERT INTO messages(id, conversation_id, seq, role, parts, plain, status, created_at, run_id, model_id, input_mode, ephemeral) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(m.id.uuidString), .text(m.conversationId.uuidString), .int(Int64(m.seq)), .text(m.role.rawValue), .text(try Self.encode(m.parts)),
              .text(m.text), .text(m.status.rawValue), .real(m.createdAt.timeIntervalSince1970), m.runId.map { .text($0.uuidString) } ?? .null,
              m.modelId.map { .text($0) } ?? .null, m.inputMode.map { .text($0) } ?? .null, .int(ephemeral ? 1 : 0)])
        if m.status == .final, !m.text.isEmpty, !ephemeral {
            try ftsRun("INSERT INTO messages_fts(plain, message_id, conversation_id) VALUES(?,?,?)", [.text(m.text), .text(m.id.uuidString), .text(m.conversationId.uuidString)])
        }
    }

    private func touch(_ id: UUID, modelId: String?) throws {
        try db.run("UPDATE conversations SET last_activity_at = ?, last_model_id = COALESCE(?, last_model_id) WHERE id = ?",
                   [.real(now().timeIntervalSince1970), modelId.map { .text($0) } ?? .null, .text(id.uuidString)])
    }

    /// Full history in order. Nothing here is ever deleted by context compaction.
    public func messages(_ conversationId: UUID, afterSeq: Int = 0) throws -> [ConversationMessage] {
        try db.query("SELECT * FROM messages WHERE conversation_id = ? AND seq > ? ORDER BY seq", [.text(conversationId.uuidString), .int(Int64(afterSeq))]).map(Self.message)
    }

    /// Crash recovery: anything still `pending` after relaunch can no longer be streaming.
    public func finalizeAbandoned() throws { try db.run("UPDATE messages SET status = 'cancelled' WHERE status = 'pending'") }

    // MARK: Search

    /// Searches titles and message text. Uses the FTS trigram index for 3+ characters, LIKE for shorter (common for Chinese).
    public func search(_ query: String, includeArchived: Bool = true, limit: Int = 50) throws -> [ConversationSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let like = "%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let rows: [[String: SQLiteDB.Value]]
        if q.count >= 3, fts {
            rows = try db.query("SELECT message_id, conversation_id, plain FROM messages_fts WHERE plain MATCH ? LIMIT ?",
                                [.text("\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""), .int(Int64(limit * 3))])
        } else {
            rows = try db.query("SELECT id AS message_id, conversation_id, plain FROM messages WHERE status = 'final' AND ephemeral = 0 AND plain LIKE ? ESCAPE '\\' LIMIT ?",
                                [.text(like), .int(Int64(limit * 3))])
        }
        var hits: [ConversationSearchHit] = [], seen = Set<UUID>()
        let titleMatches = try db.query("SELECT id FROM conversations WHERE deleted_at IS NULL AND title LIKE ? ESCAPE '\\'", [.text(like)]).compactMap { $0.str("id").flatMap(UUID.init) }
        for cid in titleMatches where seen.insert(cid).inserted {
            if let c = try conversation(cid), includeArchived || !c.archived { hits.append(.init(conversation: c, messageId: nil, snippet: c.title)) }
        }
        for r in rows {
            guard let cid = r.str("conversation_id").flatMap(UUID.init), seen.insert(cid).inserted, let c = try conversation(cid),
                  c.deletedAt == nil, includeArchived || !c.archived else { continue }
            hits.append(.init(conversation: c, messageId: r.str("message_id").flatMap(UUID.init), snippet: Self.snippet(r.str("plain") ?? "", around: q)))
            if hits.count >= limit { break }
        }
        return hits
    }

    // MARK: Attachments

    /// Stores an authorized local copy (already downscaled/re-encoded by the caller) with complete file protection.
    public func saveAttachment(conversationId: UUID, data: Data, mimeType: String = "image/jpeg", width: Int, height: Int) throws -> AttachmentRecord {
        let id = UUID()
        let rel = "\(conversationId.uuidString)/\(id.uuidString).\(mimeType == "image/png" ? "png" : "jpg")"
        let url = attachmentsRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)             // macOS (tests, tools) has no data-protection classes; the strict class fails there
        #endif
        let rec = AttachmentRecord(id: id, conversationId: conversationId, kind: "image", relativePath: rel, mimeType: mimeType, bytes: Int64(data.count),
                                   pixelWidth: width, pixelHeight: height, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), createdAt: now())
        try db.run("INSERT INTO attachments VALUES(?,?,?,?,?,?,?,?,?,?)",
                   [.text(id.uuidString), .text(conversationId.uuidString), .text("image"), .text(rel), .text(mimeType), .int(rec.bytes),
                    .int(Int64(width)), .int(Int64(height)), .text(rec.sha256), .real(rec.createdAt.timeIntervalSince1970)])
        return rec
    }

    public func attachment(_ id: UUID) throws -> AttachmentRecord? {
        try db.query("SELECT * FROM attachments WHERE id = ?", [.text(id.uuidString)]).first.map { r in
            AttachmentRecord(id: id, conversationId: UUID(uuidString: r.str("conversation_id")!)!, kind: r.str("kind")!, relativePath: r.str("path")!,
                             mimeType: r.str("mime")!, bytes: r.int("bytes")!, pixelWidth: Int(r.int("width")!), pixelHeight: Int(r.int("height")!),
                             sha256: r.str("sha256")!, createdAt: r.date("created_at")!)
        }
    }

    /// Local file for an attachment, or nil when the file is gone (deleted, restored from a partial backup…).
    public nonisolated func fileURL(_ a: AttachmentRecord) -> URL? {
        let u = attachmentsRoot.appendingPathComponent(a.relativePath)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Summaries (written by ContextManager)

    public func latestSummary(_ conversationId: UUID) throws -> ContextSummary? {
        try db.query("SELECT body FROM summaries WHERE conversation_id = ? ORDER BY version DESC LIMIT 1", [.text(conversationId.uuidString)])
            .first?.str("body").flatMap { try? AgentCoding.decoder().decode(ContextSummary.self, from: Data($0.utf8)) }
    }
    public func saveSummary(_ s: ContextSummary) throws {
        let body = String(data: try AgentCoding.encoder().encode(s), encoding: .utf8)!
        try db.run("INSERT INTO summaries VALUES(?,?,?,?,?)", [.text(s.conversationId.uuidString), .int(Int64(s.version)), .int(Int64(s.throughSeq)), .text(body), .real(s.createdAt.timeIntervalSince1970)])
    }

    // MARK: Runs

    public func recordRun(_ runId: UUID, conversationId: UUID, state: RunState) throws {
        try db.run("INSERT INTO runs VALUES(?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at",
                   [.text(runId.uuidString), .text(conversationId.uuidString), .text(state.rawValue), .real(now().timeIntervalSince1970)])
    }

    // MARK: Export

    public struct Export: Codable, Sendable { public var schemaVersion: Int; public var conversation: Conversation; public var messages: [ConversationMessage]; public var attachments: [AttachmentRecord] }
    public func export(_ id: UUID) throws -> Export? {
        guard let c = try conversation(id) else { return nil }
        let atts = try db.query("SELECT id FROM attachments WHERE conversation_id = ?", [.text(id.uuidString)]).compactMap { $0.str("id").flatMap(UUID.init) }.compactMap { try attachment($0) }
        return Export(schemaVersion: Self.schemaVersion, conversation: c, messages: try messages(id), attachments: atts)
    }

    // MARK: Helpers

    private func ftsRun(_ sql: String, _ args: [SQLiteDB.Value]) throws { if fts { try db.run(sql, args) } }

    static func encode(_ parts: [MessagePart]) throws -> String { String(data: try AgentCoding.encoder().encode(parts), encoding: .utf8)! }
    static func message(_ r: [String: SQLiteDB.Value]) -> ConversationMessage {
        ConversationMessage(id: UUID(uuidString: r.str("id")!)!, conversationId: UUID(uuidString: r.str("conversation_id")!)!, seq: Int(r.int("seq")!),
                            role: MessageRole(rawValue: r.str("role")!) ?? .user,
                            parts: (try? AgentCoding.decoder().decode([MessagePart].self, from: Data((r.str("parts") ?? "[]").utf8))) ?? [],
                            status: MessageStatus(rawValue: r.str("status")!) ?? .final, createdAt: r.date("created_at")!,
                            runId: r.str("run_id").flatMap(UUID.init), modelId: r.str("model_id"), inputMode: r.str("input_mode"))
    }
    static func snippet(_ text: String, around q: String) -> String {
        guard let r = text.range(of: q, options: .caseInsensitive) else { return String(text.prefix(60)) }
        let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
