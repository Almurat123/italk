import Testing
import Foundation
@testable import AgentRuntime

/// What the model sees when the person switches between a small on-device window and a large cloud window mid-conversation.
@Suite(.serialized) struct ModelSwitchContextTests {
    private func conversation(_ s: ConversationStore, exchanges: Int, facts: [Int: String] = [:]) async throws -> UUID {
        let c = try await s.createConversation()
        try await s.append(userMsg(c.id, "我叫王小明。我对花生过敏，千万不要推荐含花生的菜。")); try await s.append(botMsg(c.id, "记住了。"))
        for i in 0..<exchanges {
            try await s.append(userMsg(c.id, facts[i] ?? "随便聊聊第\(i)个话题：" + String(repeating: "这是一些填充内容", count: 20)))
            try await s.append(botMsg(c.id, String(repeating: "这是助手的较长回答", count: 20)))
        }
        try await s.append(userMsg(c.id, "总结一下我们说过的重点"))
        return c.id
    }
    private let small = ContextBudget(contextWindow: 4096, reservedOutput: 512)
    private let large = ContextBudget(contextWindow: 128_000, reservedOutput: 2048)

    @Test func aLargerWindowGetsTheOriginalConversationBackAndTheSummaryIsKeptForLater() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let id = try await conversation(s, exchanges: 30)
        let total = try await s.messages(id).count
        let a = try await cm.build(conversationId: id, budget: small, supportsVision: false, summarizer: EchoSummarizer())
        #expect(a.status.compactedThisTurn && a.messages.first?.role == .system && a.status.summaryVersion != nil)

        let b = try await cm.build(conversationId: id, budget: large, supportsVision: false)
        #expect(b.status.summaryVersion == nil && b.status.summarizedThroughSeq == 0)
        #expect(b.messages.count == total && b.messages.first?.role == .user && b.messages.first?.text.contains("我叫王小明") == true)
        #expect(b.messages.allSatisfy { $0.role != .system }, "no summary text written for another model leaks into the larger window")

        let c = try await cm.build(conversationId: id, budget: small, supportsVision: false)
        #expect(!c.status.compactedThisTurn && c.status.summaryVersion == a.status.summaryVersion, "switching back reuses the stored summary instead of recomputing it")
        #expect(c.messages.first?.text.contains("花生过敏") == true)
    }

    @Test func aLongBacklogMeetingASmallWindowKeepsTheFactsOfTheWholeBacklog() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let id = try await conversation(s, exchanges: 400, facts: [200: "会议改到下午5点，不是4点。", 330: "晚饭不要放香菜。"])
        let b = try await cm.build(conversationId: id, budget: small, supportsVision: false)
        #expect(b.status.estimatedTokens <= small.safeBudget, "\(b.status)")
        let summary = b.messages.first { $0.role == .system }?.text ?? ""
        for fact in ["花生过敏", "会议改到下午5点", "晚饭不要放香菜"] { #expect(summary.contains(fact), "lost: \(fact)") }
        #expect(b.messages.last?.text == "总结一下我们说过的重点")
        #expect(b.status.droppedMessages == 0, "the sweep made room without dropping recent turns")
        let before = try await s.messages(id).count
        #expect(before == 2 + 400 * 2 + 1, "compaction never deletes history")
    }

    @Test func hugeRecentMessagesRemainAvailableForTheRunnerToSize() async throws {
        let s = try ConversationStore(directory: convDir()); let cm = ContextManager(store: s)
        let c = try await s.createConversation()
        for i in 0..<6 { try await s.append(userMsg(c.id, "第\(i)个问题")); try await s.append(botMsg(c.id, String(repeating: "答", count: 900))) }
        try await s.append(userMsg(c.id, "最后一个问题"))
        let b = try await cm.build(conversationId: c.id, budget: ContextBudget(contextWindow: 1024, reservedOutput: 256), supportsVision: false)
        #expect(b.messages.last?.text == "最后一个问题")
        #expect(b.status.estimatedTokens > ContextBudget(contextWindow: 1024, reservedOutput: 256).safeBudget)
        #expect(b.status.droppedMessages == 0)
        #expect(b.messages.contains { $0.text == "第5个问题" })
    }
}
