import Foundation

/// A restrained attention rhythm. Coordinates are normalized, not camera tracking.
public enum CharacterGaze {
    public struct Point: Sendable {
        public let x: Double; public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public static func sample(at time: Double) -> Point {
        guard time.isFinite else { return Point(x: 0, y: 0) }
        let t = max(0, time), cycle = t.truncatingRemainder(dividingBy: 14)
        func glance(_ start: Double, _ end: Double) -> Double {
            guard cycle > start && cycle < end else { return 0 }
            let edge = min(1, min((cycle - start) / 0.20, (end - cycle) / 0.20))
            return edge * edge * (3 - 2 * edge)
        }
        let left = glance(4.2, 5.15), right = glance(8.0, 8.95), up = glance(11.8, 12.7)
        return Point(x: -0.32 * left + 0.27 * right + 0.10 * up + sin(t * 0.73) * 0.018,
                     y: -0.04 * left + 0.07 * right - 0.23 * up + sin(t * 0.49) * 0.012)
    }
}
