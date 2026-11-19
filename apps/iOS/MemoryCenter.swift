import Foundation
import Observation
import UIKit
import AgentRuntime
import AssistantCore

/// A change the agent made to memory without the person typing it ("已记住 …"), so the UI can show a chip with Undo.
struct MemoryNotice: Identifiable, Equatable {
    enum Change: Equatable { case added, updated, forgotten }
    let id = UUID()
    var change: Change
    var text: String
    var itemId: UUID
    /// What undo restores for `.updated` / `.forgotten`.
    var previous: MemoryItem?
}

/// Personal memory for the UI. Backed by `MemoryStore` (a local file separate from conversation transcripts); the agent's
/// memory tools and the Memory screen read and write the same items. Deleting here removes the text everywhere on the device.
@MainActor @Observable final class MemoryCenter {
    private(set) var items: [MemoryItem] = []
    private(set) var settings = MemorySettings()
    private(set) var notice: MemoryNotice?
    private(set) var loaded = false
    /// iCloud sync of memory between the person's own devices (no iTalk account involved). Off until switched on; says plainly when it cannot work.
    private(set) var syncStatus: MemorySyncStatus = .off
    var syncEnabled: Bool { UserDefaults.standard.bool(forKey: Self.syncKey) }
    @ObservationIgnored private var syncEngine: MemorySyncEngine?
    @ObservationIgnored private static let syncKey = "italk.memory.icloudSync"

    @ObservationIgnored let store: MemoryStore
    @ObservationIgnored private weak var platform: AgentPlatform?

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("iTalk", isDirectory: true)
        store = (try? MemoryStore(url: dir?.appendingPathComponent("memory.json"))) ?? (try! MemoryStore())
        // Back in the foreground: catch up with the person's other devices (a no-op unless iCloud sync is switched on).
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
    }
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    /// Switch on and the iTalk privacy switch for memory (Settings › 隐私与权限) agree: either one off stops reading and learning.
    var isActive: Bool { settings.enabled && (platform?.settings.isOn(.memory) ?? true) }

    func bind(platform: AgentPlatform) { self.platform = platform }

    func load(legacy: [MemoryRecord] = []) async {
        if !legacy.isEmpty {
            try? await store.importLegacy(legacy.map { ($0.id, $0.content, $0.sensitive, $0.createdAt, $0.updatedAt, $0.revision) })
        }
        await reload()
        loaded = true
    }

    private func reload() async {
        items = await store.all()
        settings = await store.settings()
    }

    // MARK: UI operations

    func add(_ text: String, kind: MemoryKind = .fact) async throws {
        _ = try await store.add(text: text, kind: kind, source: .user, sensitive: MandarinRouter.isPotentiallySensitive(text), respectSwitch: false)
        await reload()
    }

    func update(_ id: UUID, text: String? = nil, kind: MemoryKind? = nil, pinned: Bool? = nil, expectedRevision: Int? = nil) async throws {
        let sensitive = text.map { MandarinRouter.isPotentiallySensitive($0) }
        try await store.update(id, text: text, kind: kind, pinned: pinned, sensitive: sensitive, expectedRevision: expectedRevision)
        await reload()
    }

    func delete(_ id: UUID) async { try? await store.delete(id); await reload() }
    func deleteAll() async { try? await store.deleteAll(); notice = nil; await reload() }

    func setEnabled(_ on: Bool) async {
        var s = settings; s.enabled = on
        try? await store.setSettings(s)
        platform?.settings.set(.memory, on)
        await reload()
    }
    func setReferenceChatHistory(_ on: Bool) async { var s = settings; s.referenceChatHistory = on; try? await store.setSettings(s); await reload() }
    func setLearnAutomatically(_ on: Bool) async { var s = settings; s.learnAutomatically = on; try? await store.setSettings(s); await reload() }

    func search(_ query: String) -> [MemoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Notices (agent-made changes are visible and reversible)

    func dismissNotice() { notice = nil }

    func undo(_ n: MemoryNotice) async {
        switch n.change {
        case .added: try? await store.delete(n.itemId)
        case .updated: if let p = n.previous { try? await store.update(n.itemId, text: p.text, kind: p.kind, pinned: p.pinned, sensitive: p.sensitive) }
        case .forgotten: if let p = n.previous { _ = try? await store.add(text: p.text, kind: p.kind, source: p.source, sensitive: p.sensitive, pinned: p.pinned, respectSwitch: false) }
        }
        if notice?.id == n.id { notice = nil }
        await reload()
    }

    // MARK: iCloud sync

    /// Switches iCloud sync on or off. On: each device keeps its own encrypted file in the app's iCloud Drive folder and merges the others' files.
    func setSyncEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Self.syncKey)
        if on { await startSync() } else {
            await syncEngine?.leave(); syncEngine = nil; syncStatus = .off
        }
    }

    /// Called when the app becomes active and after the person changes something: a round of merging with the other devices.
    func syncNow() async {
        guard syncEnabled else { return }
        if syncEngine == nil { await startSync(); return }
        syncStatus = .syncing
        let report = await syncEngine!.sync()
        apply(report)
        await reload()
    }

    private func startSync() async {
        let transport = ICloudDriveSyncTransport()
        if case .failure(let why) = transport.available() { syncEngine = nil; syncStatus = .unavailable(Self.explain(why)); return }
        guard let key = SyncKeychain.key() else { syncStatus = .unavailable("无法创建加密密钥。请确认已开启 iCloud 钥匙串。"); return }
        let engine = MemorySyncEngine(store: store, transport: transport, crypto: AESGCMSyncCrypto(keyData: key), deviceId: SyncKeychain.deviceId())
        syncEngine = engine; syncStatus = .syncing
        await engine.start()
        apply(await engine.sync())
        await reload()
    }

    private func apply(_ r: MemorySyncEngine.Report) {
        if let e = r.error { syncStatus = .offline(e) }
        else if r.otherKeyFiles > 0 && r.devicesSeen == 0 { syncStatus = .unavailable("另一台设备的加密密钥还没有通过 iCloud 钥匙串同步过来。请稍后再试，并确认两台设备都开启了 iCloud 钥匙串。") }
        else { syncStatus = .synced(.now) }
    }

    private static func explain(_ e: SyncTransportError) -> String {
        switch e { case .unavailable(let why): why; case .notDownloadedYet: "iCloud 文件还在下载，稍后会自动重试。" }
    }

    // MARK: Agent tools

    func hooks() -> MemoryHooks {
        MemoryHooks(
            enabled: { [weak self] in self?.isActive ?? false },
            save: { [weak self] text in
                guard let self else { return .refused("记忆暂不可用") }
                do {
                    let r = try await self.store.add(text: text, kind: .fact, source: .agent, sensitive: MandarinRouter.isPotentiallySensitive(text))
                    self.notice = MemoryNotice(change: r.outcome == .added ? .added : .updated, text: r.item.text, itemId: r.item.id)
                    await self.reload()
                    return r.outcome == .added ? .saved(id: r.item.id.uuidString) : .merged(id: r.item.id.uuidString)
                } catch MemoryStoreError.refusedSecret { return .refused("这条内容像是密码、证件号、银行卡号或密钥，iTalk 不会记住这类信息。") }
                catch MemoryStoreError.invalid { return .refused("记忆需要是一句简短的话（500 字以内）。") }
                catch { return .refused("这条记忆未保存。") }
            },
            search: { [weak self] query in
                guard let self else { return [] }
                // Health-related memories stay out of tool results while a cloud model is in use unless the person allowed it.
                let allowSensitive = !(self.platform?.cloudInUse ?? false) || (self.platform?.settings.isOn(.cloudHealthData) ?? false)
                return await self.store.search(query, limit: 10, includeSensitive: allowSensitive).map { ($0.id.uuidString, $0.text) }
            },
            update: { [weak self] id, text in
                guard let self, let uuid = UUID(uuidString: id), let before = await self.store.item(uuid) else { return false }
                guard (try? await self.store.update(uuid, text: text, sensitive: MandarinRouter.isPotentiallySensitive(text))) != nil else { return false }
                self.notice = MemoryNotice(change: .updated, text: text, itemId: uuid, previous: before)
                await self.reload(); return true
            },
            forget: { [weak self] id in
                guard let self, let uuid = UUID(uuidString: id), let before = await self.store.item(uuid) else { return false }
                guard (try? await self.store.delete(uuid)) == true else { return false }
                self.notice = MemoryNotice(change: .forgotten, text: before.text, itemId: uuid, previous: before)
                await self.reload(); return true
            },
            source: store,
            learn: { [weak self] text, conversationId in
                // What the person says about themselves is remembered (corrections replace the old item); the change is shown with Undo.
                guard let self, self.isActive, self.settings.learnAutomatically else { return }
                let changes = await self.store.learn(from: text, conversationId: conversationId)
                guard let last = changes.last else { return }
                self.notice = MemoryNotice(change: last.kind == .added ? .added : .updated, text: last.item.text, itemId: last.item.id, previous: last.previous)
                await self.reload()
            })
    }
}
