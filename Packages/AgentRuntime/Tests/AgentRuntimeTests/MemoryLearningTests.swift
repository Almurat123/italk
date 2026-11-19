import Testing
import Foundation
@testable import AgentRuntime

@Suite struct MemoryExtractorTests {
    private func texts(_ s: String) -> [String] { MemoryExtractor.candidates(from: s).map(\.text) }

    @Test func learnsWhatPeopleSayAboutThemselves() {
        #expect(texts("我叫王小明") == ["用户的名字是王小明"])
        #expect(texts("以后叫我小明") == ["称呼用户为「小明」"])
        #expect(texts("我住在杭州，我在阿里巴巴上班") == ["用户住在杭州", "用户在阿里巴巴工作"])
        #expect(texts("我现在搬到了上海") == ["用户住在上海"])
        #expect(texts("我是一名医生") == ["用户的职业是医生"])
        #expect(texts("我喜欢喝咖啡") == ["用户喜欢咖啡"] || texts("我喜欢喝咖啡") == ["用户喜欢喝咖啡"])
        #expect(texts("我不吃香菜") == ["用户不喜欢香菜"])
        #expect(texts("我老婆叫李梅") == ["用户的老婆叫李梅"])
        #expect(texts("我最近在准备搬家") == ["用户最近在准备搬家"])
        #expect(texts("以后回答简短一点") == ["长期指令：以后简短一点"])
        #expect(texts("My name is Alice") == ["The user's name is Alice"])
        #expect(texts("I live in Berlin.") == ["The user lives in Berlin"])
        #expect(texts("I'm allergic to peanuts") == ["The user is allergic to peanuts"])
    }

    @Test func healthStatementsAreSensitive() {
        let c = MemoryExtractor.candidates(from: "我对花生过敏。我有高血压。")
        #expect(c.map(\.text) == ["用户对花生过敏", "用户有高血压"] && c.allSatisfy(\.sensitive))
        #expect(c.map(\.slot) == ["allergy:花生", "condition:高血压"])
    }

    @Test func ignoresQuestionsHypotheticalsQuotesAndPastedDocuments() {
        for s in ["我住在哪里比较好？", "你知道我住在杭州吗", "如果我住在北京会怎么样", "假设我叫张三", "比如我喜欢咖啡的话", "他说我住在上海", "我喜欢什么？", "How do I live in Berlin?",
                  "what if I like tea"] { #expect(texts(s).isEmpty, "learned from: \(s)") }
        #expect(texts(String(repeating: "我住在杭州。", count: 400)).isEmpty, "a long paste is not a statement about the person")
        #expect(texts("请把这段翻译成英文：我住在杭州，我喜欢咖啡").count <= 2)
    }

    @Test func neverLearnsSecrets() {
        #expect(texts("我的密码是 hunter2hunter2，我住在杭州") == ["用户住在杭州"], "only the clause with the secret is skipped")
        #expect(texts("我叫 sk-abcdefghijklmnopqrstuv1234").isEmpty)
    }

    @Test func standingInstructionsNeedShortExplicitSentences() {
        #expect(texts("以后你回答的时候请一律使用中文并且不要用表情符号")  .count <= 1)
        let long = "以后" + String(repeating: "请", count: 10) + String(repeating: "做一件很长很长的事情", count: 8)
        #expect(MemoryExtractor.candidates(from: long).allSatisfy { $0.kind != .instruction })
    }
}

@Suite struct MemoryLearningTests {
    private func store(learn: Bool = true, enabled: Bool = true) async throws -> MemoryStore {
        let s = try MemoryStore()
        try await s.setSettings(MemorySettings(enabled: enabled, referenceChatHistory: true, learnAutomatically: learn))
        return s
    }

    @Test func newStatementsAreStoredAndRepeatsAreNotDuplicated() async throws {
        let s = try await store(); let c = UUID()
        let first = await s.learn(from: "我叫王小明，我住在杭州", conversationId: c)
        #expect(first.map(\.kind) == [.added, .added] && first.allSatisfy { if case .conversation(let id) = $0.item.source { id == c } else { false } })
        let again = await s.learn(from: "我住在杭州", conversationId: c)
        #expect(again.isEmpty, "saying the same thing twice changes nothing")
        let n = await s.count
        #expect(n == 2)
    }

    @Test func aNewerStatementCorrectsTheOldOneAndUndoDataIsReported() async throws {
        let s = try await store(); let c = UUID()
        _ = await s.learn(from: "我住在杭州", conversationId: c)
        let id = await s.all().first!.id
        let changes = await s.learn(from: "不对，我搬到上海了", conversationId: c)
        #expect(changes.count == 1 && changes[0].kind == .updated && changes[0].previous?.text == "用户住在杭州" && changes[0].item.text == "用户住在上海")
        #expect(changes[0].item.id == id && changes[0].item.revision == 2, "the same item is corrected, not a second contradicting one")
        let n = await s.count
        #expect(n == 1)
    }

    @Test func aChangedOpinionReplacesTheEarlierOne() async throws {
        let s = try await store(); let c = UUID()
        _ = await s.learn(from: "我喜欢咖啡", conversationId: c)
        let changes = await s.learn(from: "我不喜欢咖啡了", conversationId: c)
        #expect(changes.first?.kind == .updated)
        #expect(await s.all().map(\.text) == ["用户不喜欢咖啡"])
    }

    @Test func learningRespectsTheSwitchesAndNeverStoresSecrets() async throws {
        let off = try await store(learn: false)
        let learnedOff = await off.learn(from: "我住在杭州", conversationId: UUID()), countOff = await off.count
        #expect(learnedOff.isEmpty && countOff == 0)
        let disabled = try await store(enabled: false)
        #expect(await disabled.learn(from: "我住在杭州", conversationId: UUID()).isEmpty)
        let s = try await store()
        _ = await s.learn(from: "我的密码是 correcthorsebattery，我对花生过敏", conversationId: UUID())
        #expect(await s.all().map(\.text) == ["用户对花生过敏"])
        #expect(await s.all().first?.sensitive == true)
    }

    @Test func itemsWithoutASlotStillDecodeFromOlderFiles() throws {
        let item = MemoryItem(text: "我喜欢茶", kind: .preference, source: .user)           // slot == nil is not written, exactly like a file from before slots existed
        let data = try AgentCoding.encoder().encode(item)
        #expect(!String(decoding: data, as: UTF8.self).contains("slot"))
        let back = try AgentCoding.decoder().decode(MemoryItem.self, from: data)
        #expect(back.slot == nil && back.text == "我喜欢茶" && back.id == item.id && back.kind == .preference)
        let withSlot = MemoryItem(text: "用户住在杭州", kind: .fact, source: .user, slot: "residence")
        #expect(try AgentCoding.decoder().decode(MemoryItem.self, from: AgentCoding.encoder().encode(withSlot)).slot == "residence")
    }
}

@Suite struct MemoryInContextTests {
    private func runner(kind: ProviderKind, caps: Set<Capability>, memory: MemoryStore) async -> (AgentRunner, ScriptedModelProvider) {
        let provider = ScriptedModelProvider(descriptor: .scripted(kind: kind, offline: kind != .cloudGateway), steps: [text("好的")])
        let r = AgentRunner(provider: provider, tools: ToolRegistry([]), store: InMemoryRunStore(), granted: { caps })
        await r.setMemory(memory)
        return (r, provider)
    }
    private func ask(_ r: AgentRunner, _ q: String) async throws { let id = try await r.start(conversationId: UUID(), text: q); await r.waitUntilIdle(id) }
    private func system(_ p: ScriptedModelProvider) -> String { p.requests.first?.messages.first?.text ?? "" }

    @Test func relevantMemoryReachesTheModelAndRespectsThePriorityRules() async throws {
        let s = try MemoryStore()
        try await s.add(text: "用户住在杭州", kind: .fact, source: .user); try await s.add(text: "称呼用户为「小明」", kind: .instruction, source: .user)
        try await s.add(text: "用户喜欢爬山", kind: .preference, source: .user)
        let (r, p) = await runner(kind: .localDownloaded, caps: allCaps, memory: s)
        try await ask(r, "杭州周末去哪里玩")
        let sys = system(p)
        #expect(sys.contains("用户住在杭州") && sys.contains("称呼用户为「小明」") && sys.contains("以当前说的为准") && sys.contains("不得因此忽略"))
        #expect(sys.range(of: "称呼用户")!.lowerBound < sys.range(of: "用户住在杭州")!.lowerBound, "standing instructions come first")
    }

    @Test func memoryOffMeansNothingIsSent() async throws {
        let s = try MemoryStore(); try await s.add(text: "用户住在杭州", kind: .fact, source: .user)
        try await s.setSettings(MemorySettings(enabled: false))
        let (r, p) = await runner(kind: .localDownloaded, caps: allCaps, memory: s)
        try await ask(r, "杭州天气")
        #expect(!system(p).contains("用户住在杭州"))
        let (r2, p2) = await runner(kind: .localDownloaded, caps: allCaps.subtracting([.memory]), memory: try await { let t = try MemoryStore(); try await t.add(text: "用户住在杭州", kind: .fact, source: .user); return t }())
        try await ask(r2, "杭州天气")
        #expect(!system(p2).contains("用户住在杭州"), "the iTalk privacy switch for memory also stops reading")
    }

    @Test func cloudModelsSeeMemoryOnlyWhenPersonalDataSharingIsAllowedAndSensitiveOnlyWithTheHealthSwitch() async throws {
        let s = try MemoryStore()
        try await s.add(text: "用户住在杭州", kind: .fact, source: .user); try await s.add(text: "用户对花生过敏", kind: .fact, source: .user, sensitive: true)
        let (a, pa) = await runner(kind: .cloudGateway, caps: allCaps, memory: s)               // cloud switches off (allCaps excludes them)
        try await ask(a, "杭州有什么好吃的")
        #expect(!system(pa).contains("用户住在杭州") && !system(pa).contains("花生"))
        let (b, pb) = await runner(kind: .cloudGateway, caps: allCaps.union([.cloudPersonalData]), memory: s)
        try await ask(b, "杭州有什么好吃的 花生")
        #expect(system(pb).contains("用户住在杭州") && !system(pb).contains("花生"), "health-related memory needs its own switch")
        let (c, pc) = await runner(kind: .cloudGateway, caps: allCaps.union([.cloudPersonalData, .cloudHealthData]), memory: s)
        try await ask(c, "杭州有什么好吃的 花生")
        #expect(system(pc).contains("用户对花生过敏"))
    }
}

@Suite struct ReviewFixTests {
    private func texts(_ s: String) -> [String] { MemoryExtractor.candidates(from: s).map(\.text) }

    @Test func ordinaryVerbsAfterJiaoAreNotNamesAndLikesAimedAtTheAssistantAreNotMemories() {
        for s in ["我叫了外卖", "我叫个车", "我叫醒了他", "我爱你", "我喜欢这个方案", "我喜欢你的回答"] { #expect(texts(s).isEmpty, "learned from: \(s)") }
        #expect(texts("我叫王小明") == ["用户的名字是王小明"] && texts("我喜欢爬山") == ["用户喜欢爬山"])
    }

    @Test func mergingAnUnchangedCopyDoesNotNotifyListeners() async throws {
        let a = try MemoryStore(), b = try MemoryStore()
        try await a.add(text: "用户住在杭州", kind: .fact, source: .user)
        let snapshot = await a.export()
        try await b.merge(items: snapshot.items, tombstones: snapshot.tombstones)
        let counter = Counter()
        await b.addListener { counter.bump() }
        try await b.merge(items: snapshot.items, tombstones: snapshot.tombstones)
        #expect(counter.value == 0, "nothing changed, so nothing is announced and a sync cannot keep re-triggering itself")
    }

    @Test func aSyncingEngineGoesQuietAfterItHasCaughtUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("italk-quiet-\(UUID())"), key = AESGCMSyncCrypto.newKeyData()
        let a = try MemoryStore(), b = try MemoryStore()
        try await a.add(text: "用户叫小明", kind: .fact, source: .user)
        let ea = MemorySyncEngine(store: a, transport: FolderSyncTransport(directory: folder), crypto: AESGCMSyncCrypto(keyData: key), deviceId: "a")
        let eb = MemorySyncEngine(store: b, transport: FolderSyncTransport(directory: folder), crypto: AESGCMSyncCrypto(keyData: key), deviceId: "b")
        await ea.sync(); await eb.sync(); await ea.sync()
        let counter = Counter()
        await b.addListener { counter.bump() }
        for _ in 0..<3 { await eb.sync(); await ea.sync() }
        #expect(counter.value == 0)
        let first = await eb.sync()
        #expect(first.changedLocally == 0 && !first.published)
    }
}

final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() { l.withLock { n += 1 } }; var value: Int { l.withLock { n } } }
