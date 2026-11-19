import Foundation

/// Smoothed download speed and time remaining from progress samples (monotonic seconds). Honest: nil until two samples a second apart exist.
public struct DownloadSpeedMeter: Sendable, Equatable {
    public private(set) var bytesPerSecond: Double?
    private var lastBytes: Int64?
    private var lastTime: Double?

    public init() {}

    public mutating func update(bytes: Int64, at time: Double) {
        guard let previousBytes = lastBytes, let previousTime = lastTime else { lastBytes = bytes; lastTime = time; return }
        let elapsed = time - previousTime
        guard elapsed >= 1 else { return }
        if bytes < previousBytes { bytesPerSecond = nil }           // the download restarted from an earlier point
        else {
            let instant = Double(bytes - previousBytes) / elapsed
            bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
        }
        lastBytes = bytes; lastTime = time
    }

    public func secondsRemaining(done: Int64, total: Int64) -> Double? {
        guard let speed = bytesPerSecond, speed > 0, total >= done else { return nil }
        return Double(total - done) / speed
    }

    public mutating func reset() { self = DownloadSpeedMeter() }
}
