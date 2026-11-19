import Testing
import Foundation
import CryptoKit
@testable import AgentRuntime

/// Several "devices" (a store + an engine each) sharing one folder, like iCloud Drive.
@Suite(.serialized) struct MemorySyncTests {
    final class Device {
        let store: MemoryStore, engine: MemorySyncEngine, keyData: Data
        init(folder: URL, key: Data, id: String, transport: SyncTransport? = nil) throws {
            keyData = key
            store = try MemoryStore()
            engine = MemorySyncEngine(store: store, transport: transport ?? FolderSyncTransport(directory: folder), crypto: AESGCMSyncCrypto(keyData: key), deviceId: id)
        }
        var texts: [String] { get async { await store.all().map(\.text).sorted() } }
    }
    private func setup(_ n: Int = 2) throws -> (folder: URL, devices: [Device]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("italk-sync-\(UUID())"), key = AESGCMSyncCrypto.newKeyData()
        return (folder, try (0..<n).map { try Device(folder: folder, key: key, id: "dev\($0)") })
    }
    /// Two rounds each reach a fixed point for any number of devices.
    private func settle(_ ds: [Device]) async { for _ in 0..<3 { for d in ds { await d.engine.sync() } } }

    @Test func aMemoryAddedOnOneDeviceAppearsOnTheOtherAndEditsFlowBack() async throws {
        let (_, d) = try setup(); let a = d[0], b = d[1]
        let item = try await a.store.add(text: "用户住在杭州", kind: .fact, source: .user).item
        let r = await a.engine.sync(); #expect(r.published && r.error == nil)
        let rb = await b.engine.sync(); #expect(rb.devicesSeen == 1 && rb.changedLocally >= 1)
        let tb0 = await b.texts
        #expect(tb0 == ["用户住在杭州"])
        try await b.store.update(item.id, text: "用户住在杭州西湖区"); await settle(d)
        let t_a_b1 = await a.texts, t_a_b2 = await b.texts
        #expect(t_a_b1 == ["用户住在杭州西湖区"] && t_a_b2 == ["用户住在杭州西湖区"])
    }

    @Test func aDeletionPropagatesAndAStaleCopyCannotBringTheItemBack() async throws {
        let (_, d) = try setup(3); let a = d[0], b = d[1], c = d[2]
        let item = try await a.store.add(text: "用户不吃香菜", kind: .preference, source: .user).item
        await settle(d); #expect(await c.texts == ["用户不吃香菜"])
        _ = try await a.store.delete(item.id)                 // A deletes; B and C are "offline" (they do not sync yet)
        await a.engine.sync()
        await b.engine.sync()                                 // B now learns of the deletion and publishes its (empty) state
        await c.engine.sync()                                 // C still had the old copy and published it earlier; it must not resurrect it
        await settle(d)
        for x in d { let t = await x.texts; #expect(t == [], "device still has the deleted item") }
    }

    @Test func aLaterEditBeatsAnEarlierDeletion() async throws {
        let (_, d) = try setup(); let a = d[0], b = d[1]
        let item = try await a.store.add(text: "用户喜欢爬山", kind: .preference, source: .user).item
        await settle(d)
        _ = try await a.store.delete(item.id)
        try await Task.sleep(for: .milliseconds(20))
        try await b.store.update(item.id, text: "用户很喜欢爬山")   // edited after the deletion on another device
        await settle(d)
        let t_a_b1 = await a.texts, t_a_b2 = await b.texts
        #expect(t_a_b1 == ["用户很喜欢爬山"] && t_a_b2 == ["用户很喜欢爬山"], "the person's later edit is kept on both devices")
    }

    @Test func twoDevicesThatLearnedDifferentValuesForTheSameSlotConvergeOnTheNewerOne() async throws {
        let (_, d) = try setup(); let a = d[0], b = d[1]
        _ = try await a.store.upsert(MemoryCandidate(text: "用户住在杭州", kind: .fact, sensitive: false, slot: "residence"), source: .user)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await b.store.upsert(MemoryCandidate(text: "用户住在上海", kind: .fact, sensitive: false, slot: "residence"), source: .user)
        await settle(d)
        let t_a_b1 = await a.texts, t_a_b2 = await b.texts
        #expect(t_a_b1 == ["用户住在上海"] && t_a_b2 == ["用户住在上海"])
    }

    @Test func aNewDeviceRestoresEverythingExceptWhatWasDeleted() async throws {
        let (folder, d) = try setup(); let a = d[0]
        for t in ["用户叫小明", "用户住在杭州", "用户喜欢茶"] { try await a.store.add(text: t, kind: .fact, source: .user) }
        let gone = try await a.store.add(text: "临时的事", kind: .context, source: .user).item
        _ = try await a.store.delete(gone.id)
        await a.engine.sync()
        let fresh = try Device(folder: folder, key: try keyOf(d), id: "newphone")
        let report = await fresh.engine.sync()
        #expect(report.devicesSeen == 1 && report.published)
        let tf = await fresh.texts, tombs = await fresh.store.export().tombstones
        #expect(tf == ["用户住在杭州", "用户叫小明", "用户喜欢茶"])
        #expect(tombs.contains { $0.id == gone.id }, "the deletion came along, so it stays deleted everywhere")
    }
    private func keyOf(_ d: [Device]) throws -> Data { d[0].keyData }

    @Test func deleteAllEverywhere() async throws {
        let (_, d) = try setup(); let a = d[0], b = d[1]
        for t in ["一", "二", "三"] { try await a.store.add(text: "用户的\(t)", kind: .fact, source: .user) }
        await settle(d); let nb = await b.texts.count; #expect(nb == 3)
        try await b.store.deleteAll(); await settle(d)
        let ea = await a.texts, eb = await b.texts
        #expect(ea.isEmpty && eb.isEmpty)
    }

    @Test func offlineIsHarmlessAndTheNextSuccessfulRoundCatchesUp() async throws {
        struct Down: SyncTransport {
            func publish(deviceId: String, data: Data) async throws { throw SyncTransportError.unavailable("offline") }
            func fetchAll() async throws -> [SyncFile] { throw SyncTransportError.unavailable("offline") }
            func remove(deviceId: String) async throws {}
        }
        let (folder, _) = try setup(0); let key = AESGCMSyncCrypto.newKeyData()
        let offline = try Device(folder: folder, key: key, id: "x", transport: Down())
        try await offline.store.add(text: "用户住在杭州", kind: .fact, source: .user)
        let r = await offline.engine.sync()
        let local = await offline.texts
        #expect(r.error != nil && !r.published); #expect(local == ["用户住在杭州"], "local data is untouched")
        let state = await offline.engine.state
        if case .offline = state {} else { Issue.record("state should be offline, was \(state)") }
        let online = try Device(folder: folder, key: key, id: "x", transport: nil)           // same device id, connectivity back
        try await online.store.add(text: "用户住在杭州", kind: .fact, source: .user)
        let ok = await online.engine.sync(); #expect(ok.published && ok.error == nil)
    }

    @Test func filesFromADifferentKeyOrCorruptFilesAreSkippedNotFatal() async throws {
        let (folder, d) = try setup(); let a = d[0]
        try await a.store.add(text: "用户住在杭州", kind: .fact, source: .user)
        let stranger = try Device(folder: folder, key: AESGCMSyncCrypto.newKeyData(), id: "stranger")     // another person's data in the same folder
        try await stranger.store.add(text: "别人的秘密", kind: .fact, source: .user); await stranger.engine.sync()
        try Data("not a sync file".utf8).write(to: folder.appendingPathComponent("memory-broken.sync"))
        let report = await a.engine.sync()
        let ta = await a.texts
        #expect(report.unreadableFiles == 1 && report.otherKeyFiles == 1 && report.error == nil, "\(report)")
        #expect(ta == ["用户住在杭州"])
    }

    @Test func publishingIsSkippedWhenNothingChangedAndOwnFileIsNeverMergedBack() async throws {
        let (folder, d) = try setup(); let a = d[0]
        try await a.store.add(text: "用户叫小明", kind: .fact, source: .user)
        let first = await a.engine.sync(); let second = await a.engine.sync()
        #expect(first.published && !second.published && second.devicesSeen == 0)
        let before = try Data(contentsOf: folder.appendingPathComponent("memory-dev0.sync"))
        await a.engine.sync()
        #expect(try Data(contentsOf: folder.appendingPathComponent("memory-dev0.sync")) == before, "an unchanged device does not rewrite its file")
    }

    @Test func theFolderContainsOnlyEncryptedData() async throws {
        let (folder, d) = try setup(); let a = d[0]
        try await a.store.add(text: "用户对花生过敏", kind: .fact, source: .user, sensitive: true); await a.engine.sync()
        let raw = try Data(contentsOf: folder.appendingPathComponent("memory-dev0.sync"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("花生") && raw.starts(with: Data("ITSY1".utf8)))
    }

    @Test func leavingRemovesOnlyThisDevicesFile() async throws {
        let (folder, d) = try setup(); let a = d[0], b = d[1]
        try await a.store.add(text: "A 的记忆", kind: .fact, source: .user); try await b.store.add(text: "B 的记忆", kind: .fact, source: .user)
        await settle(d); await a.engine.leave()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("memory-dev0.sync").path) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("memory-dev1.sync").path))
        let na = await a.texts.count, nb = await b.texts.count
        #expect(na == 2 && nb == 2, "leaving keeps the local copies")
    }
}
