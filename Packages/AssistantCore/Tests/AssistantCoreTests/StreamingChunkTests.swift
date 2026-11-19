import Foundation
import Testing
@testable import AssistantCore

@Test func chunkStartsPointIntoTheCumulativeText() {
    var s = StreamingSpeechSplitter()
    let full = "好的，我帮你看了一下明天的安排，下午有会。记得早点出发。到时候见。"
    let chars = Array(full)
    var chunks: [StreamingSpeechSplitter.Chunk] = []
    for n in 1...chars.count { chunks += s.updateChunks(String(chars.prefix(n))) }
    chunks += s.finishChunks(full)
    #expect(chunks.map(\.text).joined() == "好的，我帮你看了一下明天的安排，下午有会。记得早点出发。到时候见。")
    #expect(chunks.first?.sourceStart == 0)
    // Every chunk starts where the previous one's source ended: nothing is skipped, nothing repeats.
    var expectedStart = 0
    for chunk in chunks {
        #expect(chunk.sourceStart == expectedStart, "\(chunk)")
        expectedStart = chunk.sourceStart + chunk.text.count
    }
    #expect(expectedStart == chars.count)
}

@Test func theStringOnlyApiIsUnchanged() {
    var a = StreamingSpeechSplitter(), b = StreamingSpeechSplitter()
    let full = "嗯。好的。今天天气晴朗，最高气温25℃。明天有雨。"
    var plain: [String] = [], rich: [String] = []
    for n in 1...full.count {
        plain += a.update(String(full.prefix(n)))
        rich += b.updateChunks(String(full.prefix(n))).map(\.text)
    }
    plain += a.finish(full); rich += b.finishChunks(full).map(\.text)
    #expect(plain == rich)
}

@Test func aMergedChunkStartsAtItsFirstSourceCharacter() {
    var s = StreamingSpeechSplitter()
    let full = "嗯。好的。今天天气晴朗，最高气温25℃。"
    var chunks: [StreamingSpeechSplitter.Chunk] = []
    for n in 1...full.count { chunks += s.updateChunks(String(full.prefix(n))) }
    chunks += s.finishChunks(full)
    #expect(chunks.first?.sourceStart == 0, "the tiny sentences are merged into the chunk that starts at the very beginning")
}

@Test func leadingNewlinesBelongToTheNextChunk() {
    var s = StreamingSpeechSplitter()
    let full = "你好，今天过得怎么样呢。\n\n我是你的小助手，随时可以帮你。"
    let chunks = s.finishChunks(full)
    #expect(chunks.count == 2 && chunks[0].sourceStart == 0)
    // The paragraph break is part of the second chunk's source. A segment declared after the break starts at the trimmed length of
    // everything before it (13 characters: the break itself is trimmed), which is exactly where this chunk starts.
    #expect(chunks[1].sourceStart == "你好，今天过得怎么样呢。".count)
}

@Test func aNewModelStepIsSpokenFromItsFirstCharacter() {
    // A tool step ends, the next model step restarts its text at zero. The answer after the tool must be heard in full.
    let preamble = "我先帮你查一下明天杭州的天气情况，请稍等一下。"
    let answer = "明天杭州晴，最高二十五度。"
    func spokenText(restarting: Bool) -> String {
        var s = StreamingSpeechSplitter()
        var spoken = ""
        for n in 1...preamble.count { spoken += s.update(String(preamble.prefix(n))).joined() }
        if restarting { spoken += s.restart(flushing: preamble).map(\.text).joined() }
        for n in 1...answer.count { spoken += s.update(String(answer.prefix(n))).joined() }
        spoken += s.finish(answer).joined()
        return spoken
    }
    #expect(spokenText(restarting: true) == preamble + answer)
    // Why the restart exists: the old offset (the preamble's length) swallows a shorter answer completely.
    #expect(spokenText(restarting: false) == preamble)
}

@Test func restartingFlushesTheTailThePreviousStepHeldBack() {
    var s = StreamingSpeechSplitter()
    let preamble = "好的，我来查一下"                 // no sentence end yet: nothing is released while it is still being written
    var spoken: [String] = []
    for n in 1...preamble.count { spoken += s.update(String(preamble.prefix(n))).map { $0 } }
    let flushed = s.restart(flushing: preamble).map(\.text)
    #expect((spoken + flushed).joined() == preamble)
    #expect(s.restart(flushing: "").isEmpty, "restarting twice releases nothing")
}
