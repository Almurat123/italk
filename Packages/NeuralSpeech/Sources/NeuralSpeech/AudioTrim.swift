import Foundation

/// Silence measurement for stitching separately synthesized sentences into natural speech.
public enum AudioTrim {
    /// RMS over 5 ms windows; anything below `thresholdDB` (dBFS) counts as silence.
    private static func isSilent(_ samples: ArraySlice<Float>, thresholdDB: Float) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return 10 * log10(max(sum / Float(samples.count), 1e-12)) < thresholdDB
    }

    /// Number of silent samples at the start, or nil while the whole buffer is still silent (speech may start later).
    public static func leadingSilence(_ x: [Float], rate: Double, thresholdDB: Float = -48) -> Int? {
        let window = max(1, Int(rate * 0.005))
        var start = 0
        while start + window <= x.count {
            if !isSilent(x[start..<(start + window)], thresholdDB: thresholdDB) { return start }
            start += window
        }
        return nil
    }

    /// Number of silent samples at the end (0 when the tail is audible).
    public static func trailingSilence(_ x: [Float], rate: Double, thresholdDB: Float = -48) -> Int {
        let window = max(1, Int(rate * 0.005))
        var end = x.count, silent = 0
        while end - window >= 0 {
            if !isSilent(x[(end - window)..<end], thresholdDB: thresholdDB) { break }
            silent += window; end -= window
        }
        return silent
    }

    /// Linear fade in/out over `milliseconds` to avoid clicks at joins.
    public static func fade(_ x: inout [Float], rate: Double, inMs: Double, outMs: Double) {
        let n = Int(rate * inMs / 1000), m = Int(rate * outMs / 1000)
        if n > 1 { for i in 0..<min(n, x.count) { x[i] *= Float(i) / Float(n) } }
        if m > 1 { for i in 0..<min(m, x.count) { x[x.count - 1 - i] *= Float(i) / Float(m) } }
    }

    /// Designed pause after a spoken chunk, from its closing punctuation (seconds, measured from the end of the speech).
    public static func pause(after text: String) -> Double {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last(where: { !"\"”’)）」』】》".contains($0) }) else { return 0.05 }
        if "。！？!?…".contains(last) { return 0.26 }
        if "；;：:\n".contains(last) { return 0.18 }
        if "，,、".contains(last) { return 0.10 }
        return 0.05
    }
}
