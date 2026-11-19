import Foundation
import Observation
import ImageIO
import AgentRuntime
import AssistantCore

/// Owns the conversation database for the app: persistence for `AppModel`, the sidebar's data, search, and the context
/// manager used by local models. Visual presentation is Codex's; this type is the contract (see docs/conversation-contract.md).
@MainActor @Observable final class ConversationLibrary: ConversationBackend {
    /// Active (not archived, not deleted) conversations, pinned first then most recent.
    private(set) var conversations: [Conversation] = []
    private(set) var archived: [Conversation] = []
    /// Most recently deleted conversation, restorable with `undoDelete()` until the next delete or relaunch.
    private(set) var lastDeleted: Conversation?
    private(set) var currentId: UUID?
    private(set) var historyEnabled: Bool
    private(set) var lastContextStatus: ContextStatus?
    private(set) var storageError: String?

    @ObservationIgnored private(set) var store: ConversationStore
    @ObservationIgnored private(set) var context: ContextManager
    /// user turn id → (conversation, assistant message id). Kept across conversation switches so a reply that finishes in
    /// the background is written to the conversation it belongs to, never to the one on screen.
    @ObservationIgnored private var assistantIds: [UUID: (conversation: UUID, message: UUID)] = [:]
    @ObservationIgnored private static var directory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("iTalk/Conversations", isDirectory: true)
    }

    init(historyEnabled: Bool) {
        self.historyEnabled = historyEnabled
        let s = (try? ConversationStore(directory: historyEnabled ? Self.directory : nil)) ?? (try! ConversationStore(directory: nil))
        store = s; context = ContextManager(store: s)
        Task { await self.startup() }
    }

    private func startup() async {
        try? await store.finalizeAbandoned()
        try? await store.purge()
        await refresh()
    }

    /// History setting changed. Turning it on starts persisting from the next conversation; turning it off stops writing
    /// and shows nothing persisted (existing data is kept until the user deletes it in Settings).
    func setHistoryEnabled(_ on: Bool) {
        guard on != historyEnabled else { return }
        historyEnabled = on
        do {
            let s = try ConversationStore(directory: on ? Self.directory : nil)
            store = s; context = ContextManager(store: s); currentId = nil; assistantIds = [:]   // a different database
            Task { await refresh() }
        } catch { storageError = "对话记录暂时无法打开" }
    }

    func refresh() async {
        conversations = (try? await store.list(.active)) ?? []
        archived = (try? await store.list(.archived)) ?? []
    }

    /// Sidebar sections in display order; empty groups omitted.
    func grouped(now: Date = .now) -> [(ConversationGroup, [Conversation])] {
        let g = Dictionary(grouping: conversations) { ConversationGroup.group(for: $0, now: now) }
        return ConversationGroup.allCases.compactMap { k in g[k].map { (k, $0) } }
    }

    func search(_ query: String) async -> [ConversationSearchHit] { (try? await store.search(query)) ?? [] }

    /// Local file of an image attachment (for on-device Vision tools).
    func attachmentFile(_ id: UUID) async -> URL? {
        guard let rec = try? await store.attachment(id) else { return nil }
        return store.fileURL(rec)
    }
    /// Called before a conversation is deleted (the app cancels its unfinished run).
    @ObservationIgnored var willDelete: ((UUID) -> Void)?

    // MARK: Mutations (sidebar long-press actions)

    func rename(_ id: UUID, to title: String) async { try? await store.rename(id, to: title); await refresh() }
    func setPinned(_ id: UUID, _ on: Bool) async { try? await store.setPinned(id, on); await refresh() }
    func setArchived(_ id: UUID, _ on: Bool) async {
        try? await store.setArchived(id, on)
        if on, id == currentId { currentId = nil }
        await refresh()
    }
    /// Soft delete. The caller cancels any active run for this conversation first (AppModel does).
    func delete(_ id: UUID) async {
        willDelete?(id)
        lastDeleted = conversations.first { $0.id == id } ?? archived.first { $0.id == id }
        try? await store.delete(id)
        if id == currentId { currentId = nil }
        await refresh()
    }
    func undoDelete() async {
        guard let c = lastDeleted else { return }
        try? await store.restore(c.id); lastDeleted = nil
        await refresh()
    }

    // MARK: ConversationBackend

    func beginNew() { currentId = nil }

    @discardableResult
    func recordUser(turnId: UUID, text: String, images: [Data], sessionOnly: Bool, inputMode: String) async -> UUID? {
        do {
            let cid: UUID
            if let currentId { cid = currentId } else { cid = try await store.createConversation().id; currentId = cid }
            var parts: [MessagePart] = text.isEmpty ? [] : [.text(text)]
            for data in images {
                let (w, h) = Self.pixelSize(data)
                let a = try await store.saveAttachment(conversationId: cid, data: data, width: w, height: h)
                parts.append(.image(attachmentId: a.id))
            }
            try await store.append(ConversationMessage(id: turnId, conversationId: cid, role: .user, parts: parts, inputMode: inputMode), sessionOnly: sessionOnly)
            let aid = UUID(); assistantIds[turnId] = (cid, aid)
            try await store.append(ConversationMessage(id: aid, conversationId: cid, role: .assistant, parts: [], status: .pending), sessionOnly: sessionOnly)
            await refresh()
            return cid
        } catch { storageError = "对话未能保存"; return currentId }
    }

    func recordAssistant(turnId: UUID, text: String, final: Bool, failed: Bool, modelId: String?, sessionOnly: Bool) async {
        guard let (cid, aid) = assistantIds[turnId] else { return }
        let status: MessageStatus = failed ? .failed : final ? .final : .cancelled
        try? await store.update(ConversationMessage(id: aid, conversationId: cid, role: .assistant, parts: text.isEmpty ? [] : [.text(text)],
                                                    status: status, modelId: modelId))
        await refresh()
    }

    func open(_ id: UUID) async -> [ConversationTurn] {
        guard let messages = try? await store.messages(id) else { return [] }
        currentId = id
        var turns: [ConversationTurn] = []
        for m in messages {
            switch m.role {
            case .user:
                var images: [ImageAttachment] = []
                for aid in m.imageIds {
                    if let rec = try? await store.attachment(aid), let url = store.fileURL(rec), let data = try? Data(contentsOf: url) {
                        images.append(ImageAttachment(id: aid, data: data))
                    }
                }
                var t = ConversationTurn(id: m.id, question: m.text, images: images, createdAt: m.createdAt)
                t.state = .complete
                turns.append(t)
            case .assistant:
                guard !turns.isEmpty else { continue }
                assistantIds[turns[turns.count - 1].id] = (id, m.id)
                turns[turns.count - 1].answer = m.text
                turns[turns.count - 1].state = switch m.status { case .final: .complete; case .failed: .failed; case .cancelled, .pending: .cancelled }
            default: continue
            }
        }
        return turns
    }

    /// One-time import of the old flat Q&A history so nothing the user saved before disappears.
    func importLegacy(_ entries: [HistoryEntry]) async {
        let key = "italk.conversations.legacyImported"
        guard historyEnabled, !UserDefaults.standard.bool(forKey: key), !entries.isEmpty else { return }
        for e in entries {
            guard let c = try? await store.createConversation() else { continue }
            _ = try? await store.append(ConversationMessage(conversationId: c.id, role: .user, parts: [.text(e.question)], createdAt: e.date))
            _ = try? await store.append(ConversationMessage(conversationId: c.id, role: .assistant, parts: [.text(e.answer)], createdAt: e.date))
        }
        UserDefaults.standard.set(true, forKey: key)
        await refresh()
    }

    func noteContext(_ s: ContextStatus) { lastContextStatus = s }

    private static func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }
}
