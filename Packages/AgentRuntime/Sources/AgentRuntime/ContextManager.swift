import Foundation

/// Persisted, versioned summary of conversation messages up to `throughSeq`. Original messages are never deleted.
public struct ContextSummary: Codable, Sendable, Equatable {
    public struct Fact: Codable, Sendable, Equatable { public var text: String; public var sourceSeq: Int; public var kind: String }
    public var conversationId: UUID
    public var version: Int
    public var throughSeq: Int
    /// Deterministically extracted, verbatim user statements that must survive (numbers, dates, negations, requirements, corrections).
    public var facts: [Fact]
    /// Optional model-written narrative. Advisory only: facts are the guarantee.
    public var narrative: String?
    public var method: String               // "deterministic" | "model+deterministic"
    public var modelId: String?
    public var createdAt: Date

    public func rendered() -> String {
        var s = "【较早对话的摘要（原始记录仍保存在本机）】"
        if let narrative, !narrative.isEmpty { s += "\n概述：" + narrative }
        if !facts.isEmpty { s += "\n用户明确说过的要点（以此为准）：\n" + facts.map { "- " + $0.text }.joined(separator: "\n") }
        return s
    }
}

/// Live numbers for the UI and diagnostics.
public struct ContextStatus: Codable, Sendable, Equatable {
    public var contextWindow: Int
    public var safeBudget: Int
    public var estimatedTokens: Int
    public var includedMessages: Int
    public var totalMessages: Int
    public var summaryVersion: Int?
    public var summarizedThroughSeq: Int
    public var compactedThisTurn: Bool
    public var compactionFailed: Bool
    /// Messages that had to be left out of this request because even the summary plus the protected recent turns did not fit.
    public var droppedMessages: Int = 0
    public var buildMillis: Double
    public var compactionMillis: Double?
}

public struct ContextBudget: Sendable, Equatable {
    public var contextWindow: Int
    public var reservedOutput: Int
    public var reservedTools: Int
    /// Fraction of the window we allow ourselves to fill (estimates are approximate).
    public var safetyFraction: Double = 0.8
    public var safeBudget: Int { max(256, Int(Double(contextWindow) * safetyFraction) - reservedOutput - reservedTools) }
    public init(contextWindow: Int, reservedOutput: Int, reservedTools: Int = 0) {
        self.contextWindow = contextWindow; self.reservedOutput = reservedOutput; self.reservedTools = reservedTools
    }
}

/// Conservative token estimate for models without an exact counter. Per-character costs were fitted on 1,836 samples (this project's Chinese documentation,
/// Swift, JavaScript, JSON and Markdown) tokenized with the Qwen3.5 tokenizer, then scaled by 1.2: on that corpus it under-counts 2% of samples (never by more than
/// ~10%) and over-counts by ~19% at the median. The earlier "one token per Chinese character, one per 3.5 other characters" rule over-counted Chinese prose by
/// 1.4–2.2x and UNDER-counted code and JSON (0.7–0.9x), which is the dangerous direction. Models that can count exactly (the on-device MLX models) never use this
/// for the final decision. Images follow Qwen3-VL geometry: one token per 32×32 pixels after resizing.
public enum TokenEstimator {
    public static func tokens(_ text: String) -> Int {
        var cjk = 0, letters = 0, digits = 0, punct = 0, space = 0, wide = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: cjk += 1
            case 0x30...0x39: digits += 1
            case 0x41...0x5A, 0x61...0x7A: letters += 1
            case 0x20, 0x09, 0x0A, 0x0D: space += 1
            case 0x1F000...0x1FAFF, 0x2600...0x27BF: wide += 1                 // emoji and symbols: often several tokens each
            case 0x80...: cjk += 1                                              // other scripts: priced like Chinese, never like Latin letters
            default: punct += 1
            }
        }
        let raw = 0.67 * Double(cjk) + 0.23 * Double(letters) + 1.97 * Double(digits) + 0.77 * Double(punct) + 0.19 * Double(space) + 2.4 * Double(wide)
        return Int(raw.rounded(.up)) + 4      // +4: role/format overhead
    }
    public static func imageTokens(width: Int, height: Int, maxPixels: Int = VisionLimits.maxPixels) -> Int {
        let (w, h) = VisionLimits.fitted(width: width, height: height, maxPixels: maxPixels)
        return max(4, (w / 32) * (h / 32)) + 2
    }
    public static func tokens(_ m: ModelMessage) -> Int {
        tokens(m.text) + m.images.reduce(0) { $0 + imageTokens(width: $1.pixelWidth, height: $1.pixelHeight) }
            + m.toolCalls.reduce(0) { $0 + tokens($1.name + $1.arguments.compactString) }
    }
}

/// Image limits for local vision. Resolution caps both latency and memory; measured on device before raising.
public enum VisionLimits {
    /// ≈ 768×768. Qwen3.5 merges 32×32 px per token → ≤ ~576 image tokens.
    public static let maxPixels = 768 * 768
    public static let maxImagesPerMessage = 3
    /// Images older than this many user turns are referenced by text only, not re-encoded.
    public static let imageTurnsInContext = 2
    public static func fitted(width: Int, height: Int, maxPixels: Int = maxPixels) -> (Int, Int) {
        guard width > 0, height > 0 else { return (32, 32) }
        let scale = min(1, (Double(maxPixels) / Double(width * height)).squareRoot())
        func round32(_ v: Double) -> Int { max(32, Int((v / 32).rounded()) * 32) }
        return (round32(Double(width) * scale), round32(Double(height) * scale))
    }
}

/// Pulls statements that must never be summarized away. Deterministic: no model involved, so it works the same on 0.8B and cloud.
public enum FactExtractor {
    static let correction = ["不是", "更正", "改成", "说错", "应该是", "纠正", "改为"]
    static let negation = ["不要", "别", "不能", "不用", "不想", "禁止", "不吃", "不喝", "没有", "不可以", "不准", "过敏"]
    static let requirement = ["必须", "一定要", "务必", "记住", "要求", "只要", "只能", "请用", "以后", "希望你", "我的名字", "我叫"]
    /// Quantities that matter: numbers with a time/date/money/measurement unit, clock times, relative days. A bare ordinal
    /// such as 「第3个」 is not a fact.
    static let dateTime = try! NSRegularExpression(pattern:
        "\\d+(\\.\\d+)?\\s*(点|时|分|号|日|月|年|岁|元|块|万|千|百|公斤|斤|克|千克|kg|公里|米|km|%|％|次|天|周|小时|分钟|毫克|mg|毫升|ml|度|°)|\\d{1,2}[:：]\\d{2}|[一二三四五六七八九十两百千万]+(点|号|日|月|年|岁|元|块|公斤|斤|天|周|小时|分钟)|今天|明天|后天|昨天|周[一二三四五六日天]|星期[一二三四五六日天]")

    public static func facts(from messages: [ConversationMessage]) -> [ContextSummary.Fact] {
        var out: [ContextSummary.Fact] = []
        for m in messages where m.role == .user && m.status == .final {
            for sentence in split(m.text) {
                let kind: String?
                if correction.contains(where: sentence.contains) { kind = "correction" }
                else if requirement.contains(where: sentence.contains) { kind = "requirement" }
                else if negation.contains(where: sentence.contains) { kind = "negation" }
                else if dateTime.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil { kind = "number_or_date" }
                else { kind = nil }
                if let kind { out.append(.init(text: String(sentence.prefix(120)), sourceSeq: m.seq, kind: kind)) }
            }
            for p in m.parts { if case .tool(_, let name, let summary, let status) = p { out.append(.init(text: "已执行操作 \(name)（\(status)）：\(summary)", sourceSeq: m.seq, kind: "tool")) } }
        }
        return out
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { "。！？!?\n；;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }

    /// Dedupe; corrections supersede nothing automatically (both kept, newer last) so the model sees what changed.
    /// Dedupes and fits the facts into `tokenCap`. Priority when over budget: corrections, requirements, negations and tool
    /// records first (newest kept), then numbers/dates (newest kept). Original order is preserved in the output.
    public static func merge(_ old: [ContextSummary.Fact], _ new: [ContextSummary.Fact], cap: Int, tokenCap: Int = .max) -> [ContextSummary.Fact] {
        var seen = Set<String>(), all: [ContextSummary.Fact] = []
        for f in old + new { let k = f.text.filter { !$0.isWhitespace && !$0.isPunctuation }; if seen.insert(k).inserted { all.append(f) } }
        let ranked = all.indices.sorted { a, b in
            let pa = all[a].kind == "number_or_date" ? 1 : 0, pb = all[b].kind == "number_or_date" ? 1 : 0
            return pa != pb ? pa < pb : a > b
        }
        var keep = Set<Int>(), used = 0
        for i in ranked where keep.count < cap {
            let t = TokenEstimator.tokens(all[i].text) + 2
            if used + t > tokenCap { continue }
            keep.insert(i); used += t
        }
        return all.indices.filter(keep.contains).map { all[$0] }
    }
}

/// Optional model narrative for compaction. Small local models may produce poor summaries, so the result is bounded and advisory.
public protocol ContextSummarizer: Sendable {
    func summarize(previous: String?, messages: [ConversationMessage], maxCharacters: Int) async throws -> String
}

/// Uses any `ModelProvider` (local or cloud) to write a short narrative. Times out instead of stalling the turn.
public struct ProviderSummarizer: ContextSummarizer {
    let provider: any ModelProvider
    let timeout: Duration
    public init(provider: any ModelProvider, timeout: Duration = .seconds(20)) { self.provider = provider; self.timeout = timeout }
    public func summarize(previous: String?, messages: [ConversationMessage], maxCharacters: Int) async throws -> String {
        let transcript = messages.map { ($0.role == .user ? "用户：" : "助手：") + $0.text.prefix(400) }.joined(separator: "\n")
        let prompt = "把下面的对话压缩成不超过\(maxCharacters)字的中文概述，只写发生过的事实，不要编造，不要省略数字、日期和否定。" +
            (previous.map { "\n已有概述：\($0)" } ?? "") + "\n对话：\n" + transcript
        let req = GenerationRequest(messages: [.init(role: .user, text: prompt)], maxTokens: maxCharacters + 64, temperature: 0.2)
        return try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask {
                var out = ""
                for try await e in provider.generate(req) { if case .textDelta(let d) = e { out += d } }
                return out
            }
            g.addTask { try await Task.sleep(for: timeout); throw ProviderError.failed("summary timeout") }
            let r = try await g.next()!; g.cancelAll()
            return String(TextSanitizer.plain(r).prefix(maxCharacters))
        }
    }
}

/// Builds the model input for one turn from the conversation database and compacts incrementally when it gets too large.
public actor ContextManager {
    public struct Settings: Sendable {
        public var keepRecentUserTurns = 4
        public var compactionChunkTokens = 1_500
        public var factCap = 40
        public var narrativeMaxCharacters = 300
        public var maxChunksPerTurn = 3
        public init() {}
    }
    private let store: ConversationStore
    private let settings: Settings
    public init(store: ConversationStore, settings: Settings = .init()) { self.store = store; self.settings = settings }

    /// What the model sees in place of a reply that failed or was cancelled (the partial text, if any, is unreliable).
    public static let unfinishedNote = "（这一次回答没有完成。）"

    public struct Build: Sendable { public var messages: [ModelMessage]; public var status: ContextStatus }

    /// - Parameters:
    ///   - supportsVision: images become `ModelMessage.images` only when the provider really accepts them.
    ///   - summarizer: nil → deterministic facts only (recommended for chat-only small models).
    public func build(conversationId: UUID, budget: ContextBudget, supportsVision: Bool,
                      summarizer: (any ContextSummarizer)? = nil, modelId: String? = nil) async throws -> Build {
        let start = ContinuousClock.now
        let all = try await store.messages(conversationId).filter { $0.role != .system && ($0.status == .final || $0.status == .pending || ($0.role == .assistant && ($0.status == .failed || $0.status == .cancelled))) }
        var summary = try await store.latestSummary(conversationId)
        var compacted = false, failed = false, compactionMs: Double?

        func assemble(_ summary: ContextSummary?) async throws -> [ModelMessage] {
            var tail = all.filter { $0.seq > (summary?.throughSeq ?? 0) }
            // Turns that did not finish stay visible as a short note, so "continue" after a failure still sees what was asked. Asking the same thing again
            // after a failure replaces the earlier attempt instead of piling up identical requests.
            var i = 0
            while i + 2 < tail.count {
                let a = tail[i], b = tail[i + 1], c = tail[i + 2]
                if a.role == .user, a.status == .final, b.role == .assistant, b.status != .final, c.role == .user, c.text == a.text { tail.removeSubrange(i...(i + 1)) } else { i += 1 }
            }
            var out: [ModelMessage] = []
            if let summary { out.append(.init(role: .system, text: summary.rendered())) }
            let userSeqs = tail.filter { $0.role == .user }.map(\.seq)
            let imageCutoff = userSeqs.suffix(VisionLimits.imageTurnsInContext).first ?? Int.max
            for m in tail {
                var images: [ModelImage] = []
                var text = m.text
                for id in m.imageIds {
                    guard let a = try await store.attachment(id) else { text += "\n[图片已删除]"; continue }
                    if supportsVision, m.seq >= imageCutoff, let url = store.fileURL(a) {
                        images.append(.init(attachmentId: id, filePath: url.path, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight))
                    } else if store.fileURL(a) == nil { text += "\n[图片文件已不存在]" }
                    else { text += supportsVision ? "\n[之前发送的一张图片]" : "\n[图片：当前模型不能查看图片]" }
                }
                if m.role == .assistant, m.status == .failed || m.status == .cancelled { text = ContextManager.unfinishedNote }
                out.append(.init(role: m.role == .assistant ? .assistant : .user, text: text, images: images))
            }
            return out
        }

        var messages = try await assemble(summary)
        var total = messages.reduce(0) { $0 + TokenEstimator.tokens($1) }
        // Switching to a model with a larger window (or back from a small one) must not leave the person with a summary written for the small model:
        // when the original messages fit this model's budget, they are used as they are. The stored summary stays for the next small-window turn.
        var usedOriginals = false
        if summary != nil, all.reduce(0, { $0 + TokenEstimator.tokens($1.text) }) <= budget.safeBudget {
            let original = try await assemble(nil)
            let originalTotal = original.reduce(0) { $0 + TokenEstimator.tokens($1) }
            if originalTotal <= budget.safeBudget { messages = original; total = originalTotal; usedOriginals = true }
        }
        let dropped = 0
        if total > budget.safeBudget {
            let cStart = ContinuousClock.now
            // Bounded: at most `maxChunksPerTurn` incremental steps per turn so a long backlog cannot stall one reply.
            for _ in 0..<settings.maxChunksPerTurn where total > budget.safeBudget {
                do {
                    guard let s = try await compact(all: all, previous: summary, budget: budget, summarizer: summarizer, modelId: modelId, conversationId: conversationId) else { break }
                    summary = s; compacted = true
                } catch { failed = true; break }     // keep the last valid summary; never lose messages
                messages = try await assemble(summary)
                total = messages.reduce(0) { $0 + TokenEstimator.tokens($1) }
            }
            // Still over (a long backlog met a small window): the facts of the WHOLE backlog are extracted deterministically, which needs no model call and
            // therefore no chunk limit, so nothing the person said is lost just because it was not reached this turn.
            for _ in 0..<6 where total > budget.safeBudget {
                do {
                    guard let s = try await compact(all: all, previous: summary, budget: budget, summarizer: nil, modelId: modelId, conversationId: conversationId, unbounded: true) else { break }
                    summary = s; compacted = true
                } catch { failed = true; break }
                messages = try await assemble(summary)
                total = messages.reduce(0) { $0 + TokenEstimator.tokens($1) }
            }
            compactionMs = (ContinuousClock.now - cStart).millis
            // Still too big (e.g. one huge message): older images may be omitted with an explicit marker.
            while total > budget.safeBudget, let i = messages.indices.dropLast().first(where: { !messages[$0].images.isEmpty }) {
                messages[i].images = []; messages[i].text += "\n[图片已省略]"; total = messages.reduce(0) { $0 + TokenEstimator.tokens($1) }
            }
            // CONTEXT MEMORY
            // Updated: 2026-10-31
            // Status: mixed
            // Why: The protected recent turns are not covered by the stored summary.
            // Debug Goal: Keep those turns for the runner to size or reject, rather than silently lose conversational facts.
            // Search Tags: context manager protected recent turns silent message loss
            // Invariants:
            // - Unsummarized recent messages stay in their original order.
            // - An oversized context reaches the runner for an honest fit decision.
            // Failure Modes:
            // - Dropping a recent turn makes a follow-up forget what the user said.
            // - Treating the estimated budget as a hard limit discards usable context.
        }
        let status = ContextStatus(contextWindow: budget.contextWindow, safeBudget: budget.safeBudget, estimatedTokens: total,
                                   includedMessages: messages.filter { $0.role != .system }.count, totalMessages: all.count,
                                   summaryVersion: usedOriginals ? nil : summary?.version, summarizedThroughSeq: usedOriginals ? 0 : (summary?.throughSeq ?? 0),
                                   compactedThisTurn: compacted, compactionFailed: failed, droppedMessages: dropped,
                                   buildMillis: (ContinuousClock.now - start).millis, compactionMillis: compactionMs)
        return Build(messages: messages, status: status)
    }

    /// Summarizes the oldest unsummarized messages outside the protected window, in bounded chunks. Returns the new summary.
    private func compact(all: [ConversationMessage], previous: ContextSummary?, budget: ContextBudget,
                         summarizer: (any ContextSummarizer)?, modelId: String?, conversationId: UUID, unbounded: Bool = false) async throws -> ContextSummary? {
        let from = previous?.throughSeq ?? 0
        let userSeqs = all.filter { $0.role == .user }.map(\.seq)
        let protectedFrom = userSeqs.suffix(settings.keepRecentUserTurns).first ?? Int.max
        // Never compact a pending message or anything at/after it (unfinished tool work, approvals, streaming output).
        let firstPending = all.first { $0.status == .pending || $0.parts.contains { if case .tool(_, _, _, let s) = $0 { s != "completed" && s != "failed" } else { false } } }?.seq ?? Int.max
        let limit = min(protectedFrom, firstPending)
        var chunk: [ConversationMessage] = [], tokens = 0
        for m in all where m.seq > from && m.seq < limit {
            let t = TokenEstimator.tokens(m.text)
            if !unbounded && !chunk.isEmpty && tokens + t > settings.compactionChunkTokens * 3 { break }
            chunk.append(m); tokens += t
        }
        // End on a complete exchange so a question is never separated from its answer.
        // A single user message is also an incomplete exchange when the next assistant message is protected.
        while let last = chunk.last, last.role == .user { chunk.removeLast() }
        guard let through = chunk.last?.seq else { return nil }

        let facts = FactExtractor.merge(previous?.facts ?? [], FactExtractor.facts(from: chunk), cap: settings.factCap,
                                        tokenCap: max(200, budget.safeBudget / 4))
        var narrative = previous?.narrative, method = "deterministic"
        if let summarizer {
            if let n = try? await summarizer.summarize(previous: previous?.narrative, messages: chunk, maxCharacters: settings.narrativeMaxCharacters),
               !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                narrative = n; method = "model+deterministic"
            }
        }
        let summary = ContextSummary(conversationId: conversationId, version: (previous?.version ?? 0) + 1, throughSeq: through, facts: facts,
                                     narrative: narrative, method: method, modelId: method == "deterministic" ? nil : modelId, createdAt: .now)
        try await store.saveSummary(summary)   // throws → caller keeps the previous valid summary
        return summary
    }
}

extension Duration { var millis: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 } }
