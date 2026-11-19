import Foundation

// MARK: - Model Center (per-artifact state; browsing or downloading never changes the active model)

public struct DownloadProgress: Codable, Sendable, Equatable {
    public var fraction: Double
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Smoothed; nil until there is enough data to be honest about it.
    public var bytesPerSecond: Double?
    public var secondsRemaining: Double?
    /// Display name of the current download source ("ModelScope"…).
    public var source: String?
    public init(fraction: Double, bytesDone: Int64, bytesTotal: Int64, bytesPerSecond: Double? = nil, secondsRemaining: Double? = nil, source: String? = nil) {
        self.fraction = fraction; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond; self.secondsRemaining = secondsRemaining; self.source = source
    }
}

public enum ModelInstallState: Codable, Sendable, Equatable {
    case notInstalled
    /// Some bytes are on disk from an earlier attempt (resume continues from them).
    case partial(bytesDone: Int64)
    case queued
    case downloading(DownloadProgress)
    case paused(DownloadProgress)
    case verifying
    case installed
    /// Weights are being read into memory.
    case loading
    /// Weights are resident in memory.
    case loaded
    case failed(String)
    /// A newer pinned version exists in the manifest.
    case updateAvailable
}

public enum ModelEntryKind: String, Codable, Sendable {
    case languageModel
    /// Shared weights that every voice of an engine needs.
    case voiceBase
    case voicePack
    /// Small helper models (turn detection, voice activity…).
    case utility
}

public struct ModelEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: ModelEntryKind
    public var name: String
    public var subtitle: String
    public var state: ModelInstallState
    public var totalBytes: Int64
    /// The model/voice currently used for conversations/speech.
    public var isActive: Bool
    /// Switching/deleting right now would disturb a running conversation (the UI should explain, not hide the control).
    public var busyReason: String?
    /// Capability claims split in two: what the developer advertises vs what iTalk implemented and verified.
    public var card: ModelCard?
    public var requiresBase: String?
    public init(id: String, kind: ModelEntryKind, name: String, subtitle: String, state: ModelInstallState, totalBytes: Int64, isActive: Bool,
                busyReason: String? = nil, card: ModelCard? = nil, requiresBase: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.subtitle = subtitle; self.state = state; self.totalBytes = totalBytes
        self.isActive = isActive; self.busyReason = busyReason; self.card = card; self.requiresBase = requiresBase
    }
}
