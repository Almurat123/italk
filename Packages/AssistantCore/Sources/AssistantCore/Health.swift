import Foundation

public struct SleepInterval: Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case inBed, awake, asleep, core, deep, rem }
    public let start: Date
    public let end: Date
    public let stage: Stage
    public let source: String
    public init(start: Date, end: Date, stage: Stage, source: String) {
        self.start = start; self.end = end; self.stage = stage; self.source = source
    }
}

public enum HealthMath {
    // CONTEXT MEMORY
    // Updated: 2026-10-25
    // Status: verified
    // Why: In-bed records and imported sleep stages overlap.
    // Debug Goal: Sleep totals must not double count overlapping intervals.
    // Search Tags: merge touching intervals sleep in bed duplicate sources
    // Invariants:
    // - In-bed and awake never contribute to asleep duration.
    // - Invalid and zero-length intervals contribute nothing.
    // Failure Modes:
    // - Summing durations counts duplicate wearable imports twice.
    // - Counting in-bed duration invents sleep.
    public static func sleepDuration(_ samples: [SleepInterval], within window: DateInterval) -> TimeInterval {
        let intervals = samples.filter { $0.stage != .inBed && $0.stage != .awake }
            .compactMap { sample -> DateInterval? in
                let start = max(sample.start, window.start), end = min(sample.end, window.end)
                return end > start ? DateInterval(start: start, end: end) : nil
            }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var active: DateInterval?
        for interval in intervals {
            if let current = active, interval.start <= current.end {
                active = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += active?.duration ?? 0
                active = interval
            }
        }
        return total + (active?.duration ?? 0)
    }

    public static func mean(_ values: [Double?], required: Int = 5) -> Double? {
        let available = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard available.count >= required else { return nil }
        return available.reduce(0, +) / Double(available.count)
    }
}

public struct HealthEvidence: Codable, Sendable {
    public enum State: String, Codable, Sendable { case available, partial, stale, inaccessible }
    public var metric: String
    public var value: Double?
    public var unit: String
    public var measuredAt: Date?
    public var computedAt: Date
    public var state: State
    public var source: String
    public init(metric: String, value: Double?, unit: String, measuredAt: Date?, state: State, source: String) {
        self.metric = metric; self.value = value; self.unit = unit; self.measuredAt = measuredAt
        computedAt = .now; self.state = state; self.source = source
    }
}
