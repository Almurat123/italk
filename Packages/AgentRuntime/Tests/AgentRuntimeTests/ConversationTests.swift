import Foundation
import Testing
@testable import AgentRuntime

func convDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("italk-conv-\(UUID())") }
func userMsg(_ c: UUID, _ t: String, parts extra: [MessagePart] = []) -> ConversationMessage { .init(conversationId: c, role: .user, parts: [.text(t)] + extra) }
func botMsg(_ c: UUID, _ t: String) -> ConversationMessage { .init(conversationId: c, role: .assistant, parts: [.text(t)], modelId: "qwen3.5-2b-4bit") }

@Suite(.serialized) struct ConversationStoreTests {
    @Test func persistsAcrossReopenInOrderWithAutomaticTitle() async throws {
        let dir = convDir()
        let s1 = try ConversationStore(directory: dir)
        let c = try await s1.createConversation()
        try await s1.append(userMsg(c.id, "帮我规划一下周末去杭州的行程。要轻松一点"))
        try await s1.append(botMsg(c.id, "好的，第一天去西湖。"))
        try await s1.append(userMsg(c.id, "第二天呢？"))
        let s2 = try ConversationStore(directory: dir)              // "restart"
        let msgs = try await s2.messages(c.id)
        #expect(msgs.map(\.seq) == [1, 2, 3])
        #expect(msgs.map(\.text) == ["帮我规划一下周末去杭州的行程。要轻松一点", "好的，第一天去西湖。", "第二天呢？"])
        let conv = try await s2.conversation(c.id)!
        #expect(conv.title == "规划一下周末去杭州的行程" && conv.messageCount == 3 && conv.lastModelId == "qwen3.5-2b-4bit")
    }

    @Test func renamePinArchiveDeleteRestorePurge() async throws {
        let s = try ConversationStore(directory: convDir())
        let a = try await s.createConversation(), b = try await s.createConversation()
        try await s.append(userMsg(a.id, "第一个对话"))
        try await s.rename(a.id, to: "我的旅行")
        try await s.append(userMsg(a.id, "再问一个"))              // user title must not be overwritten
        let v1 = try await s.conversation(a.id)?.title
        #expect(v1 == "我的旅行")
        try await s.setPinned(b.id, true)
        let v2 = try await s.list().first?.id
        #expect(v2 == b.id)
        try await s.setArchived(b.id, true)
        let v3 = try await s.list(.archived)
        let v4 = try await s.list().map(\.id)
        #expect(v4 == [a.id] && v3.map(\.id) == [b.id])
        let v5 = try await s.conversation(b.id)?.pinned
        #expect(v5 == false)
        try await s.delete(a.id)
        let v6 = try await s.list(.deleted), v7 = try await s.list()
        #expect(v7.isEmpty && v6.map(\.id) == [a.id])
        try await s.restore(a.id)
        let v8 = try await s.messages(a.id).count
        #expect(v8 == 2)
        try await s.delete(a.id)
        try await s.purge(olderThan: -1)                             // purge everything soft-deleted
        let v9 = try await s.messages(a.id)
        let v10 = try await s.conversation(a.id)
        #expect(v10 == nil && v9.isEmpty)
    }

    @Test func chineseSearchShortAndLong() async throws {
        let s = try ConversationStore(directory: convDir())
        let a = try await s.createConversation(), b = try await s.createConversation()
        try await s.append(userMsg(a.id, "明天早上八点提醒我吃药"))
        try await s.append(userMsg(b.id, "推荐几本历史书"))
        let v11 = try await s.search("吃药").map(\.conversation.id)
        #expect(v11 == [a.id])         // 2 chars → LIKE
        let long = try await s.search("提醒我吃药")                                   // ≥3 → FTS trigram
        #expect(long.map(\.conversation.id) == [a.id] && long.first?.snippet.contains("提醒我吃药") == true)
        let v12 = try await s.search("历史书").map(\.conversation.id)
        #expect(v12 == [b.id])
        try await s.delete(b.id)
        let gone = try await s.search("历史书")
        #expect(gone.isEmpty)
    }

    @Test func pendingMessagesAreNotFinalAndAreClosedAfterCrash() async throws {
        let dir = convDir()
        let s = try ConversationStore(directory: dir)
        let c = try await s.createConversation()
        var m = try await s.append(.init(conversationId: c.id, role: .assistant, parts: [.text("正在生")], status: .pending))
        let v13 = try await s.search("正在生").isEmpty
        #expect(v13)                    // unstable text is not indexed
        m.parts = [.text("正在生成的完整回答")]; m.status = .final
        try await s.update(m)
        let v14 = try await s.search("完整回答").count
        #expect(v14 == 1)
        _ = try await s.append(.init(conversationId: c.id, role: .assistant, parts: [.text("半")], status: .pending))
        try await ConversationStore(directory: dir).finalizeAbandoned()
        let v15 = try await ConversationStore(directory: dir).messages(c.id).last?.status
        #expect(v15 == .cancelled)
    }

    @Test func attachmentsArePersistedAndMissingFilesDetected() async throws {
        let s = try ConversationStore(directory: convDir())
        let c = try await s.createConversation()
        let a = try await s.saveAttachment(conversationId: c.id, data: Data(repeating: 1, count: 2048), width: 640, height: 480)
        try await s.append(userMsg(c.id, "这是什么？", parts: [.image(attachmentId: a.id)]))
        let rec = try await s.attachment(a.id)!
        #expect(s.fileURL(rec) != nil && rec.sha256.count == 64)
        try FileManager.default.removeItem(at: s.fileURL(rec)!)
        #expect(s.fileURL(rec) == nil)
        let export = try await s.export(c.id)!
        #expect(export.messages.first?.imageIds == [a.id] && export.attachments.count == 1)
    }

    @Test func sessionOnlyMessagesAreContextButNotHistory() async throws {
        let dir = convDir()
        let s = try ConversationStore(directory: dir)
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "今天天气不错"))
        try await s.append(userMsg(c.id, "我最近血压有点高"), sessionOnly: true)
        let all = try await s.messages(c.id), found = try await s.search("血压")
        #expect(all.count == 2 && found.isEmpty)
        let reopened = try await ConversationStore(directory: dir).messages(c.id)
        #expect(reopened.map(\.text) == ["今天天气不错"])
    }

    @Test func ephemeralStoreTouchesNoDisk() async throws {
        let s = try ConversationStore(directory: nil)
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "不保存的对话"))
        let v16 = try await s.messages(c.id).count
        #expect(v16 == 1)
    }

    @Test func groupsForSidebar() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func conv(_ ago: Double, pinned: Bool = false) -> Conversation {
            Conversation(id: UUID(), title: "t", titleSource: .automatic, createdAt: now, lastActivityAt: now.addingTimeInterval(-ago * 86_400), pinned: pinned,
                         archived: false, deletedAt: nil, lastModelId: nil, messageCount: 1, preview: "", hasUnfinishedRun: false)
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        #expect(ConversationGroup.group(for: conv(0.01), now: now, calendar: cal) == .today)
        #expect(ConversationGroup.group(for: conv(3), now: now, calendar: cal) == .previous7Days)
        #expect(ConversationGroup.group(for: conv(20), now: now, calendar: cal) == .previous30Days)
        #expect(ConversationGroup.group(for: conv(90), now: now, calendar: cal) == .older)
        #expect(ConversationGroup.group(for: conv(90, pinned: true), now: now, calendar: cal) == .pinned)
        #expect(ConversationTitler.title(from: "请问今天杭州天气怎么样？") == "今天杭州天气怎么样")
        #expect(ConversationTitler.title(from: "   ") == "新对话")
    }
}

struct FailingSummarizer: ContextSummarizer {
    func summarize(previous: String?, messages: [ConversationMessage], maxCharacters: Int) async throws -> String { throw ProviderError.failed("boom") }
}
struct EchoSummarizer: ContextSummarizer {
    func summarize(previous: String?, messages: [ConversationMessage], maxCharacters: Int) async throws -> String { "聊了\(messages.count)条消息" }
}

@Suite(.serialized) struct ContextManagerTests {
    /// 30 exchanges with facts sprinkled early, then check what reaches the model.
    func longConversation(_ s: ConversationStore) async throws -> UUID {
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "我叫王小明。我对花生过敏，千万不要推荐含花生的菜。"))
        try await s.append(botMsg(c.id, "记住了。"))
        try await s.append(userMsg(c.id, "我的航班是10月30日下午3点45分。"))
        try await s.append(botMsg(c.id, "好的。"))
        try await s.append(userMsg(c.id, "预算是两千元，不是三千元。"))
        try await s.append(botMsg(c.id, "明白，预算两千。"))
        for i in 0..<30 {
            try await s.append(userMsg(c.id, "随便聊聊第\(i)个话题：" + String(repeating: "这是一些填充内容", count: 20)))
            try await s.append(botMsg(c.id, String(repeating: "这是助手的较长回答", count: 20)))
        }
        try await s.append(userMsg(c.id, "我刚才说的预算是多少？"))
        return c.id
    }

    @Test func smallConversationIsPassedThroughUnchanged() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "你好")); try await s.append(botMsg(c.id, "你好！")); try await s.append(userMsg(c.id, "今天几号"))
        let b = try await cm.build(conversationId: c.id, budget: .init(contextWindow: 4096, reservedOutput: 512), supportsVision: false)
        #expect(b.messages.map(\.text) == ["你好", "你好！", "今天几号"] && !b.status.compactedThisTurn && b.status.summaryVersion == nil)
    }

    @Test func compactionKeepsFactsRecentTurnsAndOriginalHistory() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let id = try await longConversation(s)
        let before = try await s.messages(id).count
        let budget = ContextBudget(contextWindow: 4096, reservedOutput: 512)
        let b = try await cm.build(conversationId: id, budget: budget, supportsVision: false, summarizer: EchoSummarizer())
        #expect(b.status.compactedThisTurn && b.status.estimatedTokens <= budget.safeBudget, "\(b.status)")
        let summaryText = b.messages.first { $0.role == .system }?.text ?? ""
        for fact in ["花生过敏", "10月30日下午3点45分", "两千元，不是三千元", "我叫王小明"] { #expect(summaryText.contains(fact), "lost: \(fact)") }
        #expect(b.messages.last?.text == "我刚才说的预算是多少？")
        let v17 = try await s.messages(id).count
        #expect(v17 == before, "compaction must not delete history")
        // Incremental: a second long build bumps the version rather than starting over.
        for _ in 0..<10 { try await s.append(userMsg(id, String(repeating: "更多内容", count: 40))); try await s.append(botMsg(id, String(repeating: "回答", count: 60))) }
        let b2 = try await cm.build(conversationId: id, budget: budget, supportsVision: false, summarizer: EchoSummarizer())
        #expect((b2.status.summaryVersion ?? 0) > (b.status.summaryVersion ?? 0))
        #expect(b2.messages.first { $0.role == .system }?.text.contains("花生过敏") == true)
    }

    @Test func summarizerFailureFallsBackToFacts() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let id = try await longConversation(s)
        let b = try await cm.build(conversationId: id, budget: .init(contextWindow: 4096, reservedOutput: 512), supportsVision: false, summarizer: FailingSummarizer())
        #expect(b.status.compactedThisTurn && !b.status.compactionFailed)
        let v18 = try await s.latestSummary(id)?.method
        #expect(v18 == "deterministic")
        #expect(b.messages.first?.text.contains("花生过敏") == true)
    }

    @Test func pendingToolWorkIsNeverCompacted() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "提醒我明天交报告"))
        try await s.append(.init(conversationId: c.id, role: .assistant, parts: [.text("需要你确认"), .tool(callId: "c1", name: "create_reminder", summary: "明天交报告", status: "awaitingApproval")]))
        for i in 0..<40 { try await s.append(userMsg(c.id, "\(i)" + String(repeating: "填充", count: 60))); try await s.append(botMsg(c.id, String(repeating: "嗯", count: 80))) }
        let b = try await cm.build(conversationId: c.id, budget: .init(contextWindow: 4096, reservedOutput: 512), supportsVision: false)
        let v19 = try await s.latestSummary(c.id)?.throughSeq ?? 0
        #expect(v19 < 2, "approval message must stay outside any summary")
        #expect(b.status.droppedMessages == 0)
        #expect(b.messages.contains { $0.text == "提醒我明天交报告" }, "protected turns must not disappear to satisfy an estimate")
        #expect(b.messages.contains { $0.text.hasPrefix("39") }, "the latest user turn stays present")
    }

    @Test func onlyRecentImagesReachTheModelAndOnlyForVision() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let c = try await s.createConversation()
        for i in 0..<3 {
            let a = try await s.saveAttachment(conversationId: c.id, data: Data(repeating: UInt8(i), count: 100), width: 1024, height: 768)
            try await s.append(userMsg(c.id, "图\(i)是什么？", parts: [.image(attachmentId: a.id)]))
            try await s.append(botMsg(c.id, "这是图\(i)"))
        }
        let v = try await cm.build(conversationId: c.id, budget: .init(contextWindow: 8192, reservedOutput: 512), supportsVision: true)
        #expect(v.messages.map(\.images.count) == [0, 0, 1, 0, 1, 0])
        #expect(v.messages[0].text.contains("之前发送的一张图片"))
        let t = try await cm.build(conversationId: c.id, budget: .init(contextWindow: 8192, reservedOutput: 512), supportsVision: false)
        #expect(t.messages.allSatisfy { $0.images.isEmpty } && t.messages[4].text.contains("不能查看图片"))
    }

    @Test func imageTokenEstimateFollowsResize() {
        #expect(VisionLimits.fitted(width: 4032, height: 3024) == (896, 672))
        #expect(TokenEstimator.imageTokens(width: 4032, height: 3024) == 28 * 21 + 2)
        #expect(TokenEstimator.tokens("你好世界") == 7)      // 4 Chinese characters at 0.67 each, rounded up, plus 4 for the message frame
    }

    @Test func legacySnapshotsWithoutImagesStillDecode() throws {
        let old = #"{"role":"user","text":"hi","toolCalls":[]}"#
        let m = try AgentCoding.decoder().decode(ModelMessage.self, from: Data(old.utf8))
        #expect(m.images.isEmpty && m.text == "hi")
    }
}

@Test func suggestionsPreferTasksThenRecentThenStarters() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func conv(_ title: String, ago: Double, unfinished: Bool = false) -> Conversation {
        Conversation(id: UUID(), title: title, titleSource: .automatic, createdAt: now, lastActivityAt: now.addingTimeInterval(-ago * 86_400), pinned: false,
                     archived: false, deletedAt: nil, lastModelId: nil, messageCount: 2, preview: "", hasUnfinishedRun: unfinished)
    }
    let first = SuggestionEngine.suggestions(recent: [], now: now, calendar: cal)
    #expect(first.count == 3 && first.allSatisfy { $0.kind == .starter || $0.kind == .timeOfDay })
    let returning = SuggestionEngine.suggestions(recent: [conv("杭州行程", ago: 0.2), conv("报告提纲", ago: 1, unfinished: true), conv("很久以前", ago: 10), conv("另一个", ago: 0.5)], now: now, calendar: cal)
    #expect(returning.first?.kind == .unfinishedTask)
    #expect(returning.filter { $0.kind != .starter && $0.kind != .timeOfDay }.count == 2)
    #expect(!returning.contains { $0.title.contains("很久以前") })
    let dismissed = SuggestionEngine.suggestions(recent: [], now: now, calendar: cal, dismissed: Set(first.map(\.id)))
    #expect(Set(dismissed.map(\.id)).isDisjoint(with: first.map(\.id)))
}
