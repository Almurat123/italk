import Testing
import Foundation
@testable import AssistantCore

@Suite struct PreRollBufferTests {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock(); private var items: [Int] = []
        func add(_ v: Int) { lock.lock(); items.append(v); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test func backlogThenLiveInOrder() {
        let buffer = PreRollBuffer<Int>(maxFrames: 100) { _ in 1 }
        for i in 0..<5 { buffer.push(i) }
        let sink = Sink()
        buffer.attach { sink.add($0) }
        for i in 5..<8 { buffer.push(i) }
        #expect(sink.values == Array(0..<8))
        #expect(buffer.pendingFrames == 0)
    }

    @Test func nothingIsLostOrDuplicatedWhileAttachingUnderLoad() async {
        let buffer = PreRollBuffer<Int>(maxFrames: 1_000_000) { _ in 1 }
        let sink = Sink()
        let producer = Task.detached { for i in 0..<20_000 { buffer.push(i) } }
        try? await Task.sleep(for: .milliseconds(2))
        buffer.attach { sink.add($0) }          // attaches in the middle of production
        await producer.value
        #expect(sink.values == Array(0..<20_000))
    }

    @Test func oldestChunksAreDroppedBeyondTheLimitAndCounted() {
        let buffer = PreRollBuffer<Int>(maxFrames: 3) { _ in 1 }
        for i in 0..<10 { buffer.push(i) }
        let sink = Sink()
        buffer.attach { sink.add($0) }
        #expect(sink.values == [7, 8, 9])
        #expect(buffer.droppedFrames == 7)
    }

    @Test func detachKeepsLaterChunksForTheNextConsumer() {
        let buffer = PreRollBuffer<Int>(maxFrames: 100) { _ in 1 }
        let first = Sink()
        buffer.attach { first.add($0) }
        buffer.push(1)
        buffer.detach()
        buffer.push(2); buffer.push(3)
        let second = Sink()
        buffer.attach { second.add($0) }
        #expect(first.values == [1])
        #expect(second.values == [2, 3])
    }
}
