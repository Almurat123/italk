import Foundation
import Testing
@testable import AgentRuntime

private func run(_ chunks: [String]) -> (text: String, tags: [(offset: Int, tag: ToneTag)]) {
    var filter = ToneTagFilter()
    var text = "", tags: [(offset: Int, tag: ToneTag)] = []
    func take(_ pieces: [ToneTagFilter.Piece]) {
        for piece in pieces {
            switch piece {
            case .text(let t): text += t
            case .tag(let tag): tags.append((text.utf16.count, tag))
            }
        }
    }
    for chunk in chunks { take(filter.feed(chunk)) }
    take(filter.finish())
    return (text, tags)
}

/// Deterministic pseudo-random chunking (splitmix-style), so a failure reproduces.
private func chunks(of text: String, seed: UInt64) -> [String] {
    var state = seed &+ 0x9E3779B97F4A7C15
    func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % 5) + 1
    }
    var out: [String] = [], current = "", target = next()
    for ch in text {
        current.append(ch)
        if current.count >= target { out.append(current); current = ""; target = next() }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

@Test func tagAtTheStartIsStrippedAndLocated() {
    let r = run(["[tone:comforting] 别难过，慢慢来。"])
    #expect(r.text == "别难过，慢慢来。")
    #expect(r.tags.count == 1)
    #expect(r.tags[0].offset == 0)
    #expect(r.tags[0].tag.intent == .comforting)
    #expect(r.tags[0].tag.intensity == nil)
    #expect(r.tags[0].tag.isKnown)
}

@Test func tagsInTheMiddleCarryUTF16OffsetsInTheCleanText() {
    let r = run(["好的。🎉[tone:celebrating:high]完成了！[tone:cautious:low]不过要小心。"])
    #expect(r.text == "好的。🎉完成了！不过要小心。")
    #expect(r.tags.map(\.tag.intent) == [.celebrating, .cautious])
    #expect(r.tags[0].offset == "好的。🎉".utf16.count)
    #expect(r.tags[0].tag.intensity == 0.9)
    #expect(r.tags[1].offset == "好的。🎉完成了！".utf16.count)
    #expect(r.tags[1].tag.intensity == 0.3)
}

@Test func unknownLabelsAreStrippedAndNeutral() {
    for declared in ["[tone:sarcastic]", "[tone:安慰]", "[tone:]", "[tone: very-happy ]"] {
        let r = run([declared + "你好"])
        #expect(r.text == "你好", "\(declared) leaked")
        #expect(r.tags.count == 1)
        #expect(r.tags[0].tag.intent == .neutral)
        #expect(!r.tags[0].tag.isKnown)
    }
    #expect(run(["[tone:neutral]你好"]).tags[0].tag.isKnown)
}

@Test func ordinaryBracketsAreNeverTouched() {
    let text = "参见 [1] 和 [链接](https://a.b/c)，数组 a[0]，[tone] 与 [tone: 3]，【注意】看看 [语言] 和 [tonal]。"
    let r = run([text])
    #expect(r.text == text)
    #expect(r.tags.isEmpty)
}

@Test func lenientSpellingsAreAccepted() {
    let cases: [(String, CompanionIntent)] = [
        ("【语气：cautious】小心", .cautious), ("[ Tone = apologetic ]抱歉", .apologetic), ("［tone:playful］哈", .playful),
        ("〔TONE：Curious〕嗯", .curious), ("[tone : explaining]先看", .explaining), ("[语气:uncertain]也许", .uncertain),
    ]
    for (text, intent) in cases {
        let r = run([text])
        #expect(r.tags.first?.tag.intent == intent, "\(text)")
        #expect(!r.text.contains("tone") && !r.text.contains("语气") && !r.text.contains("["), "\(text) leaked: \(r.text)")
    }
}

@Test func theBareFormSmallModelsWriteIsAlsoRemoved() {
    // Seen with Qwen3.5-2B: the key is dropped ([celebrating:high]) or the tag is dressed in parentheses and emphasis.
    let cases: [(String, String, CompanionIntent, Double?)] = [
        ("[celebrating] 太棒了！", "太棒了！", .celebrating, nil), ("[celebrating:high]哇！", "哇！", .celebrating, 0.9),
        ("[uncertain:low]也许吧", "也许吧", .uncertain, 0.3), ("［Curious］嗯？", "嗯？", .curious, nil), ("【neutral】好。", "好。", .neutral, nil),
        ("*（tone: curious:low）* 这听起来", "** 这听起来", .curious, 0.3), ("(tone:explaining)因为", "因为", .explaining, nil),
    ]
    for (text, clean, intent, intensity) in cases {
        let r = run([text])
        #expect(r.text == clean, "\(text) → \(r.text)")
        #expect(r.tags.count == 1 && r.tags[0].tag.intent == intent && r.tags[0].tag.intensity == intensity, "\(text)")
    }
}

@Test func aMisspeltKeyIsAcceptedOnlyWithARealIntent() {
    // Seen with the managed cloud model: [tones:encouraging].
    let r = run(["[tones:encouraging] 来得及。"])
    #expect(r.text == "来得及。" && r.tags.first?.tag.intent == .encouraging)
    let kept = "[tonesetting: x] [tones: banana] [toned:loud]"
    #expect(run([kept]).text == kept)
    #expect(run(["[tone:banana]好"]).text == "好", "the exact key still strips an unknown value as neutral")
}

@Test func ordinaryWordsInBracketsAndBareRoundBracketsStay() {
    let text = "[理由] [编号] [curiosity] [focus] [comfortable] 好奇 (curious) 与 （playful）以及 (tone) 和 [unknown:high]"
    let r = run([text])
    #expect(r.text == text)
    #expect(r.tags.isEmpty)
}

@Test func aTagSplitOverDeltasIsRecognized() {
    let whole = run(["[tone:comforting:high] 没事的"])
    let split = run(["[to", "ne:comf", "orting:hi", "gh", "] 没", "事的"])
    #expect(split.text == whole.text)
    #expect(split.tags.map(\.tag) == whole.tags.map(\.tag))
    #expect(split.tags.map(\.offset) == whole.tags.map(\.offset))
}

@Test func chunkingNeverChangesTheResult() {
    let corpus = [
        "[tone:comforting] 别难过，慢慢来。[tone:encouraging]你已经做得很好了。",
        "日程已创建。[tone:celebrating:high]搞定！[tone:neutral]明天九点见。",
        "[1] [tone:foo]x [链接](u) [tone:focused]\n\n第二段 [tone: curious ]为什么？",
        "没有标注的普通回答，包含 [括号] 与【书名】。",
        "[tone:cautious][tone:focused]连续两个标注。",
        "结尾是半个标注 [tone:cau",
        "[celebrating:high]搞定！[uncertain]也许 [focus] [curi 与 (tone: curious:low) [explaining : low ]好",
    ]
    for (i, text) in corpus.enumerated() {
        let whole = run([text])
        let perCharacter = run(text.map(String.init))
        #expect(perCharacter.text == whole.text, "corpus \(i) per-character text")
        #expect(perCharacter.tags.map(\.tag) == whole.tags.map(\.tag), "corpus \(i) per-character tags")
        #expect(perCharacter.tags.map(\.offset) == whole.tags.map(\.offset), "corpus \(i) per-character offsets")
        for seed in 1...25 {
            let random = run(chunks(of: text, seed: UInt64(seed)))
            #expect(random.text == whole.text, "corpus \(i) seed \(seed)")
            #expect(random.tags.map(\.tag) == whole.tags.map(\.tag), "corpus \(i) seed \(seed)")
        }
    }
}

@Test func anUnfinishedCandidateIsReleasedAtTheEnd() {
    #expect(run(["答案是 [tone:comfor"]).text == "答案是 [tone:comfor")
    #expect(run(["结尾 [to"]).text == "结尾 [to")
    #expect(run(["[tone:comforting"]).tags.isEmpty)
}

@Test func exactlyOneSpaceAfterATagIsSwallowed() {
    #expect(run(["[tone:focused]  两个空格"]).text == " 两个空格")
    #expect(run(["[tone:focused]\n下一行"]).text == "\n下一行")
    #expect(run(["前文 [tone:focused] 后文"]).text == "前文 后文")
}

@Test func anOverlongCandidateIsNotATag() {
    let long = "[tone:" + String(repeating: "a", count: 60) + "]"
    #expect(run([long]).text == long)
}

@Test func stripReturnsTheSameAsStreaming() {
    let (text, tags) = ToneTagFilter.strip("[tone:curious]为什么呢？[tone:explaining:high]因为……")
    #expect(text == "为什么呢？因为……")
    #expect(tags.map(\.tag.intent) == [.curious, .explaining])
    #expect(tags.map(\.offset) == [0, "为什么呢？".utf16.count])
}

@Test func theInstructionNamesEveryDeclarableToneAndNeverNeutral() {
    let text = ToneProtocol.instruction
    #expect(ToneProtocol.declarable.count == 10)
    for intent in ToneProtocol.declarable { #expect(text.contains(intent.rawValue)) }
    #expect(!ToneProtocol.declarable.contains(.neutral))
    #expect(text.contains("不是用户的心情"))        // the reply's tone, never the person's state
}
