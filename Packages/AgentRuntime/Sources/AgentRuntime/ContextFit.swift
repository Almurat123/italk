import Foundation

/// Keeps ONE model request inside the model's window, whichever model that is (a 4K on-device model, a 32K local model, a 128K cloud model).
///
/// `ContextManager` already budgets the conversation history when a turn starts; this is the guard for everything that happens after that inside a
/// run — tool results arriving step by step, skill instructions, memory — and for a model switched mid-conversation. Rules, in the order they are applied:
/// 1. Leading system messages (instructions, memory, the conversation summary) and the person's current request are never removed.
/// 2. A tool call and its result are one unit. A result may be shortened ("…[已省略 N 字]"), but an assistant tool call is never left without its
///    result or the other way round, so every provider (including ones that reject unmatched calls) accepts the request.
/// 3. Older material goes first: results of earlier steps are shortened before the latest step's; whole older turns are dropped (oldest first)
///    before the current turn is touched.
/// 4. If nothing more can be removed and the request still does not fit, `fits` is false and the caller says so honestly instead of sending it.
/// The function is pure and deterministic: the same input always gives the same output, and fitting twice changes nothing more.
public enum ContextFit {
    public struct Outcome: Sendable, Equatable {
        public var messages: [ModelMessage]
        public var tokensBefore: Int
        public var tokensAfter: Int
        public var shortenedResults: Int
        public var droppedMessages: Int
        public var fits: Bool
        public var changed: Bool { shortenedResults > 0 || droppedMessages > 0 }
    }

    static func tokens(_ m: ModelMessage) -> Int { TokenEstimator.tokens(m) + (m.reasoningContent.map { TokenEstimator.tokens($0) } ?? 0) }
    static func total(_ ms: [ModelMessage]) -> Int { ms.reduce(0) { $0 + tokens($1) } }

    /// "head … [已省略 N 字]" keeping about `limit` characters.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[已省略 \(text.count - limit) 字]"
    }

    public static func fit(_ input: [ModelMessage], budgetTokens: Int, allowOlderTurnDrop: Bool = true) -> Outcome {
        var messages = input
        let before = total(messages)
        var shortened = 0, dropped = 0
        func done() -> Outcome { Outcome(messages: messages, tokensBefore: before, tokensAfter: total(messages), shortenedResults: shortened, droppedMessages: dropped, fits: total(messages) <= budgetTokens) }
        guard before > budgetTokens else { return done() }

        let leading = messages.prefix { $0.role == .system }.count
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }), lastUser >= leading else { return shrinkToolResults(&messages, from: leading, limits: [1500, 600, 200], budget: budgetTokens, shortened: &shortened, before: before, dropped: dropped) }
        // The latest step = the last assistant tool-call message of the current turn and the results that follow it.
        let lastStepStart = messages[lastUser...].lastIndex { $0.role == .assistant && !$0.toolCalls.isEmpty } ?? messages.count

        func shorten(_ range: Range<Int>, to limit: Int) {
            for i in range where messages[i].role == .tool && messages[i].text.count > limit + 40 { messages[i].text = clip(messages[i].text, to: limit); shortened += 1 }
        }
        // 1. Earlier results first: older history, then earlier steps of this turn.
        if total(messages) > budgetTokens { shorten(leading..<lastUser, to: 300) }
        if total(messages) > budgetTokens { shorten((lastUser + 1)..<min(lastStepStart, messages.count), to: 600) }
        return dropAndShorten(&messages, leading: leading, lastUser: lastUser, budget: budgetTokens, allowOlderTurnDrop: allowOlderTurnDrop, shortened: &shortened, dropped: &dropped, before: before)
    }

    /// Drops whole older turns (oldest first; a turn = a user message and everything up to the next one), then shortens tool results in the current turn.
    private static func dropAndShorten(_ messages: inout [ModelMessage], leading: Int, lastUser: Int, budget: Int, allowOlderTurnDrop: Bool, shortened: inout Int, dropped: inout Int, before: Int) -> Outcome {
        var lastUser = lastUser
        while allowOlderTurnDrop, total(messages) > budget, lastUser > leading {
            let next = messages[(leading + 1)..<lastUser].firstIndex { $0.role == .user } ?? lastUser
            dropped += next - leading; messages.removeSubrange(leading..<next); lastUser -= next - leading
        }
        func shorten(from start: Int, to limit: Int) {
            for i in start..<messages.count where messages[i].role == .tool && messages[i].text.count > limit + 40 { messages[i].text = clip(messages[i].text, to: limit); shortened += 1 }
        }
        for limit in [1500, 800, 400, 150] where total(messages) > budget { shorten(from: lastUser, to: limit) }
        // CONTEXT MEMORY
        // Updated: 2026-10-31
        // Status: mixed
        // Why: The current request can contain facts that cannot safely be summarized by clipping its middle.
        // Debug Goal: Reject an oversized request rather than send altered user text without consent.
        // Search Tags: context fit preserve current user request overflow
        // Invariants:
        // - The current user message remains unchanged, even if it does not fit.
        // - The caller receives fits=false when all safe reductions are exhausted.
        // Failure Modes:
        // - Clipping a long paste hides requirements and produces a misleading answer.
        // - Treating a clipped request as an unchanged fit bypasses overflow handling.
        return Outcome(messages: messages, tokensBefore: before, tokensAfter: total(messages), shortenedResults: shortened, droppedMessages: dropped, fits: total(messages) <= budget)
    }

    /// A request with no user message at all (rare): only tool results can give.
    private static func shrinkToolResults(_ messages: inout [ModelMessage], from start: Int, limits: [Int], budget: Int, shortened: inout Int, before: Int, dropped: Int) -> Outcome {
        for limit in limits where total(messages) > budget {
            for i in start..<messages.count where messages[i].role == .tool && messages[i].text.count > limit + 40 { messages[i].text = clip(messages[i].text, to: limit); shortened += 1 }
        }
        return Outcome(messages: messages, tokensBefore: before, tokensAfter: total(messages), shortenedResults: shortened, droppedMessages: dropped, fits: total(messages) <= budget)
    }

    /// Token budget for one request: the window with a safety margin (estimates are approximate), minus the reply and the tool schemas the provider is sent too.
    public static func budget(contextWindow: Int, reservedOutput: Int, toolSchemaTokens: Int, safetyFraction: Double = 0.8) -> Int {
        max(256, Int(Double(contextWindow) * safetyFraction) - reservedOutput - toolSchemaTokens)
    }
}
