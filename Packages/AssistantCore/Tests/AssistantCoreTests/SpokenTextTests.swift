import Foundation
import Testing
@testable import AssistantCore

@Test func spokenTextNeverReadsMarkup() {
    let c = SpokenText.chunks("**结论**：可以。\n```json\n{\"a\":1}\n```\n详见 https://example.com/x 。- 第一步\n- 第二步")
    let all = c.joined()
    #expect(!all.contains("**") && !all.contains("{") && !all.contains("http") && !all.contains("```"))
    #expect(all.contains("结论") && all.contains("第一步"))
}

@Test func mandarinNumberNormalization() {
    #expect(SpokenText.normalize("明天15:30开会") == "明天十五点三十分开会")
    #expect(SpokenText.normalize("早上7:05起床") == "早上七点零五分起床")
    #expect(SpokenText.normalize("2026年10/30") == "二零二六年十月三十日")
    #expect(SpokenText.normalize("湿度45%") == "湿度百分之四十五")
    #expect(SpokenText.normalize("气温-3.5℃") == "气温负三点五摄氏度")
    #expect(SpokenText.normalize("跑了5.2km") == "跑了五点二公里")
    #expect(SpokenText.normalize("每天3-5次") == "每天三到五次")
    #expect(SpokenText.normalize("心率72bpm") == "心率七十二次每分钟")
    #expect(SpokenText.normalize("电话13812345678") == "电话幺三八幺二三四五六七八")
    #expect(SpokenText.cn(10) == "十" && SpokenText.cn(105) == "一百零五" && SpokenText.cn(12030) == "一万二千零三十")
}

@Test func chunksAreSentenceSized() {
    let c = SpokenText.chunks("第一句。第二句很短！第三句？")
    #expect(c == ["第一句。", "第二句很短！", "第三句？"])
    let long = SpokenText.chunks(String(repeating: "很长的内容，", count: 30))
    #expect(long.allSatisfy { $0.count <= 66 })
}

@Test func styleResolutionRespectsUserAndClarity() {
    let s: Set<SpeechStyle> = [.neutral, .calm, .cheerful]
    #expect(SpeechStyle.resolve(userChoice: .calm, intent: .happy, consequential: false, supported: s) == .calm)
    #expect(SpeechStyle.resolve(userChoice: nil, intent: .happy, consequential: true, supported: s) == .neutral)
    #expect(SpeechStyle.resolve(userChoice: nil, intent: .happy, consequential: false, supported: s) == .cheerful)
    #expect(SpeechStyle.resolve(userChoice: nil, intent: .sad, consequential: false, supported: s) == .neutral)   // unsupported → neutral
}

@Test func voiceConsentRequiresOwnersOwnStatement() {
    var c = VoiceConsent(statement: VoiceConsent.requiredStatement, spokenTranscript: "我同意iTalk用我的声音为我自己生成语音。", ownerConfirmedSelf: true, cloudDisclosureAccepted: false, recordedAt: .now)
    #expect(c.isValid(for: .onDevice) && !c.isValid(for: .cloud))
    c.spokenTranscript = "今天天气不错"; #expect(!c.isValid(for: .onDevice))
    c.spokenTranscript = VoiceConsent.requiredStatement; c.ownerConfirmedSelf = false; #expect(!c.isValid(for: .onDevice))
}

@Test func streamingSplitterReleasesOnlyStableSentences() {
    var s = StreamingSpeechSplitter()
    #expect(s.update("好的，我帮你看").isEmpty)                          // first clause too short and unfinished
    #expect(s.update("好的，我帮你看了一下明天的安排，") == ["好的，我帮你看了一下明天的安排，"])  // early comma cut for fast first audio
    #expect(s.update("好的，我帮你看了一下明天的安排，下午15:30有会").isEmpty)
    #expect(s.update("好的，我帮你看了一下明天的安排，下午15:30有会。记得") == ["下午十五点三十分有会。"])
    #expect(s.finish("好的，我帮你看了一下明天的安排，下午15:30有会。记得早点出发。") == ["记得早点出发。"])
}

@Test func streamingSplitterMergesTinySentencesAndNeverRepeats() {
    var s = StreamingSpeechSplitter()
    let full = "嗯。好的。今天天气晴朗，最高气温25℃。"
    var spoken: [String] = []
    for n in 1...full.count { spoken += s.update(String(full.prefix(n))) }
    spoken += s.finish(full)
    #expect(spoken.joined() == "嗯。好的。今天天气晴朗，最高气温二十五摄氏度。")
    #expect(!spoken.contains("嗯。"))                                    // merged, not a separate 0.3 s blip
}

@Test func firstPhraseIsReleasedEarly() {
    var s = StreamingSpeechSplitter()
    #expect(s.update("好的呀，我来查一下").count == 1, "first comma after 4+ characters releases the opening phrase")
    var t = StreamingSpeechSplitter()
    let long = "明天杭州全天以晴为主气温在十八到二十五度之间"            // no punctuation yet
    #expect(t.update(long).count == 1, "first phrase must not wait for a sentence end")
}

@Test func traceSummaryNamesOnlyWhatHappened() {
    var t = AgentTrace(startedAt: Date(timeIntervalSince1970: 1000))
    t.elapsed = 155; t.finishedAt = Date(timeIntervalSince1970: 1155); t.state = .finished
    #expect(t.summaryTitle == "执行 · 2分35秒", "no reasoning items → never claims thinking")
    t.items = [.reasoning(ReasoningBlock(id: "a", text: "先查日程", finished: true)), .step(AgentStep(id: "1", kind: .tool, state: .succeeded, title: "查询日程"))]
    #expect(t.summaryTitle == "思考与执行 · 2分35秒" && t.hasReasoning)
    t.items = [.reasoning(ReasoningBlock(id: "a", text: "   ", finished: true))]
    #expect(!t.hasReasoning, "empty reasoning is not shown as thinking")
    #expect(TraceDuration.text(0.2) == "不到1秒" && TraceDuration.text(35) == "35秒" && TraceDuration.text(120) == "2分钟")
    let data = try! JSONEncoder().encode(t)
    #expect((try! JSONDecoder().decode(AgentTrace.self, from: data)) == t, "persisted traces round-trip")
}
