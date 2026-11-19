import Foundation
import Testing
@testable import AssistantCore

@Test func wordsNeverChangeTheExpression() {
    // The old keyword lists made these happy / sad / serious / calm / curious. A word is not a meaning: nothing is inferred now.
    let texts = ["🎉太好了！没关系，慢慢来。这个风险需要核实！你觉得呢？", "我不开心。", "很遗憾！", "注意风险！", "不用担心。", "为什么会这样？"]
    for text in texts {
        let plan = SpeechExpressionPlan(text)
        #expect(plan.phrases.allSatisfy { $0.cue.emotion == .neutral && $0.cue.emphasis == 0.35 }, "\(text)")
        #expect(plan.cue(atUTF16: 0).emotion == .neutral)
    }
}

@Test func theCallersEmotionIsCarriedByEveryClause() {
    let plan = SpeechExpressionPlan("没事的，慢慢来。我们一起看看。", fallback: .calm)
    #expect(plan.phrases.count == 3)
    #expect(plan.phrases.allSatisfy { $0.cue.emotion == .calm })
}

@Test func phrasesFollowSpokenClausesAndUTF16Offsets() {
    let text = "🎉太好了！没关系，慢慢来。你觉得呢？"
    let plan = SpeechExpressionPlan(text)
    #expect(plan.phrases.count == 4)
    let ns = text as NSString
    var covered = 0
    for phrase in plan.phrases { #expect(phrase.range.location == covered); covered += phrase.range.length }
    #expect(covered == ns.length, "the clauses cover the text exactly, emoji counted as two UTF-16 units")
    #expect(plan.phrases[0].range.length == "🎉太好了！".utf16.count)
    #expect(plan.cue(atUTF16: ns.range(of: "你觉得").location).emotion == .neutral)
}

@Test func expressionFallbackAndInvalidRangesStayBounded() {
    let plan = SpeechExpressionPlan("现在是下午三点。", fallback: .calm)
    #expect(plan.cue(atUTF16: 0).emotion == .calm)
    #expect(plan.cue(atUTF16: -1).emotion == .calm)
    #expect(plan.cue(atUTF16: 999).emotion == .calm)
    #expect(SpeechExpressionPlan("").phrases.isEmpty)
    #expect(SpeechExpressionCue(emphasis: .nan).emphasis == 0.35)
    #expect(SpeechExpressionCue(emphasis: 4).emphasis == 1)
}
