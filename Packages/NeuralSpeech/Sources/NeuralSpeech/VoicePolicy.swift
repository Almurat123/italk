import Foundation

// CONTEXT MEMORY
// Updated: 2026-10-30
// Status: verified (unit tests); device behaviour is measured with the TTS probe
// Why: A single calibration run made while the phone was locked measured 1.46x real time, was stored forever and switched every answer to the
//      retired Kokoro voice ("本机实测速度约为实时的 1.41 倍…自动使用快速声音"). The measurement must only size the playback buffer and inform the person;
//      it must never choose another engine, and one bad sample must not stick.
// Debug Goal: MOSS is the only voice engine. Speed numbers decide how much speech is queued before playback starts, nothing else.
// Search Tags: voice speed rtf lead buffer legacy kokoro migration retired
// Invariants:
// - No function here returns an engine choice. There is one engine.
// - A speed estimate is the median of recent real-use samples, so a single outlier (locked screen, thermal spike) cannot dominate it.
// - Retired voice ids always resolve to a living voice, never to silence and never to another engine.
// Failure Modes:
// - Treating the speed estimate as a gate brings the silent fallback back.
// - Persisting a calibration taken in the background makes the next launch start with an absurd lead.

/// Rolling record of how fast this device synthesizes speech (seconds of work per second of audio).
public struct SynthesisSpeedTracker: Sendable, Equatable {
    public let capacity: Int
    public private(set) var samples: [Double]
    /// Samples shorter than this are ignored: start-up cost dominates them and says nothing about steady speed.
    public static let minimumAudioSeconds = 1.5
    public static let validRange = 0.05...8.0

    public init(capacity: Int = 9, seed: Double? = nil) {
        self.capacity = max(1, capacity)
        samples = []
        if let seed, Self.validRange.contains(seed) { samples = [seed] }
    }

    /// Records one finished synthesis. Returns false when the sample was not usable.
    @discardableResult
    public mutating func record(rtf: Double, audioSeconds: Double) -> Bool {
        guard rtf.isFinite, audioSeconds.isFinite, audioSeconds >= Self.minimumAudioSeconds, Self.validRange.contains(rtf) else { return false }
        samples.append(rtf)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return true
    }

    public var count: Int { samples.count }

    /// Median of the recent samples (nil until one real measurement exists).
    public var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    public mutating func reset() { samples = [] }
}

public enum PlaybackLeadPolicy {
    public static let minimum = 0.25
    public static let maximum = 4.0
    public static let maximumExtra = 1.5

    /// Seconds of speech to have queued before the player starts. At or below ~0.6x real time a quarter second absorbs scheduling jitter;
    /// slower synthesis needs a larger head start so the sentence can finish before the queue runs dry. Never a reason to use another voice.
    public static func lead(rtf: Double?, extra: Double = 0) -> Double {
        let speed = (rtf?.isFinite ?? false) ? rtf! : 0.6
        let base = minimum + 3.0 * max(0, speed - 0.6)
        return min(maximum, base + min(max(0, extra), maximumExtra))
    }
}

/// How the person is told about speed. Purely descriptive.
public enum VoiceSpeedClass: String, Sendable, Equatable {
    case unmeasured, realtime, slightlySlow, slow
    public init(rtf: Double?) {
        guard let rtf, rtf.isFinite else { self = .unmeasured; return }
        self = rtf <= 0.85 ? .realtime : (rtf <= 1.0 ? .slightlySlow : .slow)
    }
}

/// The retired Kokoro voices and where each one's person lands now.
public enum LegacyVoiceMigration {
    /// Voice ids of the retired engine, mapped to the closest living voice.
    public static let mapping: [String: String] = [
        "zf_001": "moss-yunshu", "zf_003": "moss-shuyao",
        "zf_017": "moss-yunshu", "zf_002": "moss-yunshu", "zf_008": "moss-yunshu", "zf_018": "moss-shuyao",
        "zm_010": "moss-ajing", "zm_012": "moss-ajing", "zm_011": "moss-laofu", "zm_014": "moss-laofu",
    ]
    /// Model-store artifacts that belonged to the retired engine (base weights and every voice pack).
    public static let artifactIDs: [String] = ["kokoro-82m-coreml"] + mapping.keys.sorted().filter { !["zf_001", "zf_003"].contains($0) }.map { "kokoro-voice-\($0)" }
    /// Folder names (inside the voices store `models/` directory) the retired engine used.
    public static let directoryNames: [String] = ["kokoro-82m-coreml"]

    public static func isLegacy(_ id: String) -> Bool { id.hasPrefix("zf_") || id.hasPrefix("zm_") }

    /// The voice to use for a stored selection: itself when it is available, the mapped living voice for a retired id, otherwise the fallback.
    public static func resolve(stored: String?, available: [String], fallback: String) -> String {
        guard let stored, !stored.isEmpty else { return available.first ?? fallback }
        if available.contains(stored) { return stored }
        if let mapped = mapping[stored], available.contains(mapped) { return mapped }
        if isLegacy(stored) { return available.first ?? fallback }
        return available.first ?? fallback
    }
}

/// Fixed sentences used by the voice page preview, so every voice is judged on the same Chinese and English lines.
public enum VoicePreviewText {
    public static let chinese = "你好，我是 iTalk。今天下午三点半提醒你开会，记得提前出发哦。"
    public static let english = "If you prefer English, I can switch right away."
    public static var chunks: [String] { [chinese, english] }
}
