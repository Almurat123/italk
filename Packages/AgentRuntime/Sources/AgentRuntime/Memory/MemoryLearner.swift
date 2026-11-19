import Foundation

// Automatic memory: what the person says about themselves is noticed, stored as a short sentence they can read, edit and delete, and used in later
// conversations with any model. Separate from conversation history (which stays whole) and from context compression (which is per request).
//
// Rules that keep this safe and unsurprising:
// - Only the person's own words are read (never the assistant's text, tool results or web pages), one sentence at a time.
// - Questions, hypotheticals, quotations, long pastes and anything that looks like a secret are ignored.
// - Standing instructions are only learned from short, explicit sentences ("以后叫我小明"), never from pasted text.
// - A newer statement about the same thing replaces the older one (a correction) and the change is reported, so the UI can show it with Undo.

public struct MemoryCandidate: Sendable, Equatable {
    public var text: String
    public var kind: MemoryKind
    public var sensitive: Bool
    public var slot: String?
}

public enum MemoryExtractor {
    private struct Rule {
        let regex: NSRegularExpression
        let build: @Sendable (_ groups: [String]) -> MemoryCandidate?
    }

    private static let stop = "[^\\s，。,.!！?？；;：:“”\"'（）()]"
    private static func rule(_ pattern: String, options: NSRegularExpression.Options = [], build: @escaping @Sendable ([String]) -> MemoryCandidate?) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), build: build)
    }
    private static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let last = t.last, "了啦呢呀吧哦哈".contains(last), t.count > 2 { t.removeLast() }
        return t
    }

    private static let professions = "工程师|医生|老师|教师|学生|设计师|程序员|律师|护士|会计|销售|研究员|产品经理|作家|记者|厨师|司机|创业者|自由职业者|教授|博士生|研究生|大学生|摄影师|演员|音乐人|农民|公务员|运营|编辑|翻译|架构师|分析师"
    private static let conditions = "糖尿病|高血压|哮喘|心脏病|抑郁症|焦虑症|癫痫|过敏性鼻炎|痛风|甲亢|乳糖不耐受|乳糖不耐|偏头痛|失眠|贫血|胃病|脂肪肝|高血脂"
    private static let relatives = "老婆|妻子|老公|丈夫|女朋友|男朋友|儿子|女儿|孩子|妈妈|爸爸|母亲|父亲|哥哥|姐姐|弟弟|妹妹|爷爷|奶奶|外公|外婆|宠物|猫|狗|室友|同事|老板"

    private static let rules: [Rule] = [
        // Names and forms of address
        rule("(?:请|以后|今后|从现在起)?(?:都|就)?(?:叫我|称呼我|喊我)(\(stop){1,10})") { g in
            MemoryCandidate(text: "称呼用户为「\(tidy(g[0]))」", kind: .instruction, sensitive: false, slot: "name.call") },
        rule("我(?:的名字|名字)?(?:叫|是叫)(?![了个过着起完来去上下进出回到给把一])(\(stop){2,4})(?=$|[，。,.！!\\s])") { g in
            guard !g[0].contains(where: { "了个着过吗呢".contains($0) }) else { return nil }          // 「我叫醒了他」「我叫了外卖」: a verb, not a name
            return MemoryCandidate(text: "用户的名字是\(tidy(g[0]))", kind: .fact, sensitive: false, slot: "name") },
        rule("我的名字是(\(stop){2,6})") { g in MemoryCandidate(text: "用户的名字是\(tidy(g[0]))", kind: .fact, sensitive: false, slot: "name") },
        // Where the person lives and works
        rule("我(?:现在|目前|一直|已经)?(?:住在|住|家在|定居在|搬到了?|搬去了?|搬回了?)(\(stop){2,12})") { g in
            MemoryCandidate(text: "用户住在\(tidy(g[0]))", kind: .fact, sensitive: false, slot: "residence") },
        rule("我(?:现在|目前)?在(\(stop){2,16}?)(上班|工作|任职|读书|上学|实习|读研|读博)") { g in
            let verb = ["读书", "上学", "读研", "读博"].contains(g[1]) ? "学习" : "工作"
            return MemoryCandidate(text: "用户在\(tidy(g[0]))\(verb)", kind: .fact, sensitive: false, slot: "work") },
        rule("我是(?:一名|一个|一位|个)?(\(professions))") { g in
            MemoryCandidate(text: "用户的职业是\(g[0])", kind: .fact, sensitive: false, slot: "occupation") },
        // Health: sensitive by nature
        rule("我对(\(stop){1,10}?)过敏") { g in
            MemoryCandidate(text: "用户对\(tidy(g[0]))过敏", kind: .fact, sensitive: true, slot: "allergy:\(tidy(g[0]))") },
        rule("我(?:有|患有|得了|患了)(\(conditions))") { g in
            MemoryCandidate(text: "用户有\(g[0])", kind: .fact, sensitive: true, slot: "condition:\(g[0])") },
        // Likes and dislikes (the same object replaces the earlier opinion about it)
        rule("我(?:特别|很|最|比较|真的|一直)?(?:不喜欢|讨厌|受不了|不爱吃|不爱喝|不吃|不喝|不能吃|不能喝)(\(stop){1,16})") { g in
            return MemoryCandidate(text: "用户不喜欢\(tidy(g[0]))", kind: .preference, sensitive: false, slot: "pref:\(tidy(g[0]).lowercased())") },
        rule("我(?:特别|很|最|比较|真的|一直)?(?:喜欢|爱吃|爱喝|偏爱|偏好|钟爱|爱)(?![这那你他她它您咱])(\(stop){1,16})") { g in
            MemoryCandidate(text: "用户喜欢\(tidy(g[0]))", kind: .preference, sensitive: false, slot: "pref:\(tidy(g[0]).lowercased())") },
        // People and pets
        rule("我(?:的)?(\(relatives))(?:叫|名叫|是叫)(\(stop){1,6})") { g in
            MemoryCandidate(text: "用户的\(g[0])叫\(tidy(g[1]))", kind: .fact, sensitive: false, slot: "rel:\(g[0])") },
        // Ongoing situations
        rule("我(?:最近|这阵子|这段时间|目前|正在)(?:在)?(准备|学习|筹备|计划|装修|搬家|找工作|减肥|备考|学|练)(\(stop){0,14})") { g in
            MemoryCandidate(text: "用户最近在\(g[0])\(tidy(g[1]))", kind: .context, sensitive: false, slot: nil) },
        // Standing instructions: explicit, short, imperative
        rule("(?:以后|今后|从现在起|从now开始)(?:你)?(?:回答|回复|说话|讲话|写)?(?:请|都|要|一律|务必)?(\(stop){2,28})") { g in
            let body = tidy(g[0])
            guard body.count >= 3, !body.contains("叫我") else { return nil }
            return MemoryCandidate(text: "长期指令：以后\(body)", kind: .instruction, sensitive: false, slot: nil) },
        // English
        rule("(?i:\\bmy name is) ([A-Z][A-Za-z'’-]{1,20})\\b") { g in MemoryCandidate(text: "The user's name is \(g[0])", kind: .fact, sensitive: false, slot: "name") },
        rule("(?i:\\bcall me) ([A-Z][A-Za-z'’-]{1,20})\\b") { g in MemoryCandidate(text: "Address the user as \(g[0])", kind: .instruction, sensitive: false, slot: "name.call") },
        rule("(?i:\\bI (?:currently )?live in) ([A-Z][A-Za-z '’-]{1,30})(?=$|[,.!;])") { g in MemoryCandidate(text: "The user lives in \(tidy(g[0]))", kind: .fact, sensitive: false, slot: "residence") },
        rule("(?i:\\bI(?:'m| am) allergic to) ([A-Za-z ]{2,24})(?=$|[,.!;])") { g in MemoryCandidate(text: "The user is allergic to \(tidy(g[0]))", kind: .fact, sensitive: true, slot: "allergy:\(tidy(g[0]).lowercased())") },
        rule("\\bI (?:really |absolutely )?(?:hate|dislike|can't stand) ([A-Za-z ]{2,24})(?=$|[,.!;])", options: .caseInsensitive) { g in
            MemoryCandidate(text: "The user dislikes \(tidy(g[0]))", kind: .preference, sensitive: false, slot: "pref:\(tidy(g[0]).lowercased())") },
        rule("\\bI (?:really |absolutely )?(?:like|love|prefer|enjoy) ([A-Za-z ]{2,24})(?=$|[,.!;])", options: .caseInsensitive) { g in
            MemoryCandidate(text: "The user likes \(tidy(g[0]))", kind: .preference, sensitive: false, slot: "pref:\(tidy(g[0]).lowercased())") },
        rule("\\bfrom now on,? ([A-Za-z ,'’-]{4,60})(?=$|[.!])", options: .caseInsensitive) { g in MemoryCandidate(text: "Standing instruction: from now on \(tidy(g[0]))", kind: .instruction, sensitive: false, slot: nil) },
    ]

    static let hypothetical = try! NSRegularExpression(pattern: "如果|假如|假设|要是|万一|比如|例如|比方|假定|打个比方|if |suppose |imagine |what if |would |could ", options: .caseInsensitive)
    static let questionStart = try! NSRegularExpression(pattern: "^(谁|什么|怎么|怎样|哪|为什么|为啥|如何|能不能|可不可以|是不是|有没有|请问|how |what |why |who |where |when |can you|could you|do you|is it)", options: .caseInsensitive)
    static let reported = try! NSRegularExpression(pattern: "他说|她说|据说|听说|有人说|网上说|书上说|新闻说|they say|he said|she said", options: .caseInsensitive)
    static let sensitiveTopics = try! NSRegularExpression(pattern: "健康|病|药|症|医院|怀孕|抑郁|焦虑|债务|贷款|欠款|收入|工资|存款|离婚|宗教|政治|性取向|癌|手术|诊断", options: [])

    private static func test(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    static let interrogative = try! NSRegularExpression(pattern: "哪|什么|怎么|怎样|多少|几个|几点|谁|为什么|为啥|吗|是不是|有没有|能不能|how |what |which |who |where |why ", options: .caseInsensitive)

    /// Sentences with the punctuation that ended them: a question mark must be seen before the sentence is cut loose from it.
    private static func sentences(_ text: String) -> [(text: String, question: Bool)] {
        var out: [(String, Bool)] = [], current = ""
        for ch in text {
            if "。！？!?；;\n".contains(ch) { if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append((current, ch == "?" || ch == "？")) }; current = "" }
            else { current.append(ch) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append((current, false)) }
        return out
    }

    /// Things a person says about themselves, one short sentence each. Deterministic, so it behaves the same with any model (or none).
    public static func candidates(from message: String) -> [MemoryCandidate] {
        guard message.count <= 1200 else { return [] }                         // a long message is a document, not a statement about the person
        var out: [MemoryCandidate] = []
        for (raw, isQuestion) in sentences(message) {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            guard !isQuestion, sentence.count >= 3, sentence.count <= 90, !sentence.contains("?"), !sentence.contains("？"),
                  !test(hypothetical, sentence), !test(questionStart, sentence), !test(reported, sentence) else { continue }
            // A clause that is (or contains) a secret is skipped on its own; the rest of the sentence is still the person's own statement.
            for clause in sentence.split(whereSeparator: { "，,、".contains($0) }).map({ String($0).trimmingCharacters(in: .whitespaces) }) where clause.count >= 3 && !SecretScanner.looksSecret(clause) {
                let ns = clause as NSString
                for rule in rules {
                    for m in rule.regex.matches(in: clause, range: NSRange(location: 0, length: ns.length)) {
                        let groups = (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
                        guard var c = rule.build(groups), c.text.count <= 120, !SecretScanner.looksSecret(c.text), !test(interrogative, c.text) else { continue }
                        if c.kind == .instruction, sentence.count > 60 { continue }
                        if !c.sensitive, test(sensitiveTopics, c.text) { c.sensitive = true }
                        if !out.contains(where: { $0.text == c.text }) { out.append(c) }
                    }
                }
            }
        }
        return out
    }
}

public struct MemoryChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case added, updated, unchanged }
    public var kind: Kind
    public var item: MemoryItem
    /// The item as it was before an update (what Undo restores).
    public var previous: MemoryItem?
}

public extension MemoryStore {
    /// Stores or corrects an item for `slot`. Returns what happened so the person can see (and undo) it.
    @discardableResult
    func upsert(_ c: MemoryCandidate, source: MemorySource, now: Date = .now) throws -> MemoryChange {
        if let slot = c.slot, let existing = itemForSlot(slot) {
            if MemoryStore.similar(existing.text, c.text) { return MemoryChange(kind: .unchanged, item: existing, previous: nil) }
            let updated = try update(existing.id, text: c.text, kind: c.kind, sensitive: c.sensitive || existing.sensitive, now: now)
            return MemoryChange(kind: .updated, item: updated, previous: existing)
        }
        let r = try add(text: c.text, kind: c.kind, source: source, sensitive: c.sensitive, slot: c.slot, now: now)
        return MemoryChange(kind: r.outcome == .added ? .added : .unchanged, item: r.item, previous: nil)
    }

    /// Learns from one message of the person, if learning is on. Never throws for "nothing to learn"; refusals (secrets) are skipped silently.
    func learn(from message: String, conversationId: UUID, now: Date = .now) -> [MemoryChange] {
        let s = settings()
        guard s.enabled, s.learnAutomatically else { return [] }
        var changes: [MemoryChange] = []
        for c in MemoryExtractor.candidates(from: message) {
            if let change = try? upsert(c, source: .conversation(conversationId), now: now), change.kind != .unchanged { changes.append(change) }
        }
        return changes
    }
}
