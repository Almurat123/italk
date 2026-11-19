import Foundation

/// Keeps what a producer emits until a consumer attaches, then hands over the backlog and every later chunk in order.
///
/// This is the guarantee behind "speech after the press is never lost": the microphone starts first and pushes here; the
/// recognizer attaches whenever it is ready and receives everything from the moment of the request. `attach` drains the backlog
/// and switches to live delivery under one lock, so no chunk is dropped or duplicated between the two.
public final class PreRollBuffer<Chunk>: @unchecked Sendable {
    private let lock = NSLock()
    private var backlog: [Chunk] = []
    private var backlogFrames = 0
    private var consumer: (@Sendable (Chunk) -> Void)?
    private let maxFrames: Int
    private let frames: @Sendable (Chunk) -> Int
    /// Chunks discarded because the backlog exceeded `maxFrames` (a consumer that never attached).
    public private(set) var droppedFrames = 0

    /// - Parameters:
    ///   - maxFrames: the backlog limit; the oldest chunks are dropped beyond it.
    ///   - frames: size of a chunk in the same unit as `maxFrames` (audio frames).
    public init(maxFrames: Int, frames: @escaping @Sendable (Chunk) -> Int) { self.maxFrames = maxFrames; self.frames = frames }

    public func push(_ chunk: Chunk) {
        lock.lock(); defer { lock.unlock() }
        if let consumer { consumer(chunk); return }
        backlog.append(chunk); backlogFrames += frames(chunk)
        while backlogFrames > maxFrames, backlog.count > 1 {
            let old = backlog.removeFirst(); let n = frames(old)
            backlogFrames -= n; droppedFrames += n
        }
    }

    /// Delivers the backlog in order, then every later chunk as it is pushed.
    public func attach(_ consumer: @escaping @Sendable (Chunk) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for chunk in backlog { consumer(chunk) }
        backlog.removeAll(); backlogFrames = 0
        self.consumer = consumer
    }

    public func detach() { lock.lock(); consumer = nil; lock.unlock() }
    public var pendingFrames: Int { lock.lock(); defer { lock.unlock() }; return backlogFrames }
}
