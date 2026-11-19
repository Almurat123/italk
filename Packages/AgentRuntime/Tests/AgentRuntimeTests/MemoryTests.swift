import Testing
import Foundation
@testable import AgentRuntime

@Suite struct MemoryStoreTests {
    @Test func addSearchAndDelete() async throws {
        let store = try MemoryStore()
        let a = try await store.add(text: "我在杭州工作", kind: .fact, source: .user)
        _ = try await store.add(text: "喜欢简短的回答，不要太多寒暄", kind: .preference, source: .user)
        #expect(a.outcome == .added)
        let hits = await store.search("杭州的天气")
        #expect(hits.first?.id == a.item.id)
        #expect(try await store.delete(a.item.id))
        #expect(await store.search("杭州").isEmpty)
        #expect(await store.tombstones().count == 1)
    }

    @Test func repeatedFactMergesInsteadOfDuplicating() async throws {
        let store = try MemoryStore()
        let first = try await store.add(text: "我喜欢喝美式咖啡", kind: .preference, source: .user)
        let again = try await store.add(text: "我喜欢喝美式咖啡。", kind: .preference, source: .user)
        #expect(again.outcome == .merged)
        #expect(again.item.id == first.item.id)
        #expect(again.item.revision == 2)
        #expect(await store.count == 1)
    }

    @Test func secretsAreNeverStored() async throws {
        let store = try MemoryStore()
        for secret in ["我的银行卡号是 4111 1111 1111 1111", "密码是 hunter2024x", "key sk-abcdefghijklmnopqrstuvwxyz123456", "身份证 11010519491231002X"] {
            await #expect(throws: MemoryStoreError.refusedSecret) { try await store.add(text: secret, kind: .fact, source: .user) }
        }
        #expect(await store.count == 0)
    }

    @Test func switchOffStopsLearningAndContext() async throws {
        let store = try MemoryStore()
        _ = try await store.add(text: "称呼我小明", kind: .instruction, source: .user)
        try await store.setSettings(MemorySettings(enabled: false))
        await #expect(throws: MemoryStoreError.memoryDisabled) { try await store.add(text: "我养了一只猫", kind: .fact, source: .conversation(UUID())) }
        #expect(await store.context(for: "你好", characterBudget: 500).isEmpty)
        // stored items stay until the person deletes them
        #expect(await store.count == 1)
    }

    @Test func contextPrefersInstructionsThenRelevantWithinBudget() async throws {
        let store = try MemoryStore()
        _ = try await store.add(text: "称呼我小明", kind: .instruction, source: .user)
        _ = try await store.add(text: "我对花生过敏", kind: .fact, source: .user, sensitive: true)
        _ = try await store.add(text: "我在准备搬家到上海", kind: .context, source: .user)
        let ctx = await store.context(for: "上海的房租怎么样", characterBudget: 60)
        #expect(ctx.map(\.text).contains("称呼我小明"))
        #expect(ctx.map(\.text).contains("我在准备搬家到上海"))
        #expect(!ctx.map(\.text).contains("我对花生过敏"))      // sensitive items need the separate switch
        #expect(ctx.reduce(0) { $0 + $1.text.count } <= 60)
    }

    @Test func persistenceSurvivesReload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id: UUID
        do {
            let store = try MemoryStore(url: url)
            id = try await store.add(text: "我每周三健身", kind: .fact, source: .user).item.id
            try await store.update(id, pinned: true)
        }
        let reloaded = try MemoryStore(url: url)
        let item = await reloaded.item(id)
        #expect(item?.text == "我每周三健身")
        #expect(item?.pinned == true)
        #expect(item?.revision == 2)
    }

    @Test func syncMergeHonorsDeletionsAndNewerRevisions() async throws {
        let store = try MemoryStore()
        let a = try await store.add(text: "我用 iPhone", kind: .fact, source: .user)
        let b = try await store.add(text: "我不吃香菜", kind: .preference, source: .user)
        var remoteA = a.item; remoteA.text = "我用 iPhone 17"; remoteA.revision = 5; remoteA.updatedAt = .now.addingTimeInterval(10)
        let deleteB = MemoryTombstone(id: b.item.id, deletedAt: .now.addingTimeInterval(20), revision: 9)
        try await store.merge(items: [remoteA], tombstones: [deleteB])
        #expect(await store.item(a.item.id)?.text == "我用 iPhone 17")
        #expect(await store.item(b.item.id) == nil)
        // an old copy of the deleted item arriving later cannot bring it back
        try await store.merge(items: [b.item], tombstones: [])
        #expect(await store.item(b.item.id) == nil)
    }

    @Test func deleteAllLeavesOnlyTombstones() async throws {
        let store = try MemoryStore()
        for t in ["事实一二三", "事实四五六", "事实七八九"] { _ = try await store.add(text: t, kind: .fact, source: .user) }
        try await store.deleteAll()
        #expect(await store.count == 0)
        #expect(await store.tombstones().count == 3)
    }
}
