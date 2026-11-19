import Foundation

public enum ThermalLevel: Int, Codable, Sendable, Comparable { case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }

/// Snapshot of what the device can afford right now. Production code fills it from
/// `os_proc_available_memory()`, `ProcessInfo.thermalState`, `isLowPowerModeEnabled`, volume capacity and `MTLCreateSystemDefaultDevice()`.
public struct DeviceProfile: Sendable, Equatable {
    public var physicalMemory: Int64
    public var availableMemory: Int64
    public var freeDisk: Int64
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    public var metalAvailable: Bool
    public init(physicalMemory: Int64, availableMemory: Int64, freeDisk: Int64, thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false, metalAvailable: Bool = true) {
        self.physicalMemory = physicalMemory; self.availableMemory = availableMemory; self.freeDisk = freeDisk
        self.thermal = thermal; self.lowPowerMode = lowPowerMode; self.metalAvailable = metalAvailable
    }
}

/// One file of a model artifact. Identity is (name, bytes, sha256); where it is downloaded from is decided by `ModelSource`.
public struct ModelFile: Codable, Sendable, Equatable {
    /// Path inside the installed artifact directory.
    public var name: String
    public var bytes: Int64
    public var sha256: String
    /// Path on the source when it differs from `name` (e.g. Kokoro's `assets/` → local `g2p/`).
    public var remote: String?
    public init(name: String, bytes: Int64, sha256: String, remote: String? = nil) { self.name = name; self.bytes = bytes; self.sha256 = sha256; self.remote = remote }
    public var remotePath: String { remote ?? name }
}

public enum ModelRole: String, Codable, Sendable { case languageModel, speechSynthesis }

public struct ModelArtifact: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var version: String
    public var license: String                // license of the weights artifact, checked separately from the base model
    public var baseModelLicense: String
    public var files: [ModelFile]
    /// nil = language model (older manifests).
    public var role: ModelRole?
    /// Candidate download sources, in default preference order. `SourcePlanner` reorders them for the device's region.
    public var sources: [ModelSource]
    /// Weights resident once loaded; measure on device, do not trust file size.
    public var residentBytes: Int64
    public var kvBytesPerToken: Int64
    public var contextTokens: Int
    public var maxAutonomy: AutonomyLevel
    /// Where `maxAutonomy` came from. Defaults are conservative until a benchmark run supports a higher level.
    public var autonomySource: String
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public init(id: String, displayName: String, version: String, license: String, baseModelLicense: String, files: [ModelFile], sources: [ModelSource] = [], residentBytes: Int64, kvBytesPerToken: Int64, contextTokens: Int, maxAutonomy: AutonomyLevel, autonomySource: String) {
        self.id = id; self.displayName = displayName; self.version = version; self.license = license; self.baseModelLicense = baseModelLicense
        self.files = files; self.sources = sources; self.residentBytes = residentBytes; self.kvBytesPerToken = kvBytesPerToken; self.contextTokens = contextTokens
        self.maxAutonomy = maxAutonomy; self.autonomySource = autonomySource
    }
}

public enum ResourceVerdict: Sendable, Equatable {
    case ok(contextTokens: Int)
    /// Usable, but with a visible caveat (shorter context, low power, warm device).
    case degraded(contextTokens: Int, reason: String)
    case refuse(reason: String)
}

public enum ResourceAdvisor {
    public static let headroomFraction = 0.25
    public static let minimumContext = 512

    public static func canDownload(_ a: ModelArtifact, _ d: DeviceProfile) -> ResourceVerdict {
        let need = Int64(Double(a.totalBytes) * 1.1) + 500_000_000
        return d.freeDisk >= need ? .ok(contextTokens: a.contextTokens) : .refuse(reason: "存储空间不足：需要约 \(need / 1_000_000) MB 可用空间")
    }

    /// Decide whether loading and generating is safe. Context shrinks before the model is refused.
    public static func canRun(_ a: ModelArtifact, _ d: DeviceProfile) -> ResourceVerdict {
        if d.thermal >= .critical { return .refuse(reason: "设备过热，请稍后再试") }
        let budget = Int64(Double(d.availableMemory) * (1 - headroomFraction))
        let weights = a.residentBytes
        guard budget > weights else { return .refuse(reason: "可用内存不足以载入此模型") }
        let affordable = Int((budget - weights) / max(a.kvBytesPerToken, 1))
        var context = min(a.contextTokens, affordable)
        var reasons: [String] = []
        if context < minimumContext { return .refuse(reason: "可用内存不足以保留最小对话上下文") }
        if context < a.contextTokens { reasons.append("内存紧张，上下文已缩短") }
        if d.thermal >= .serious { context = min(context, 1024); reasons.append("设备较热，已降低负载") }
        if d.lowPowerMode { context = min(context, 2048); reasons.append("低电量模式") }
        if !d.metalAvailable { reasons.append("无 GPU 加速，速度会很慢") }
        return reasons.isEmpty ? .ok(contextTokens: context) : .degraded(contextTokens: context, reason: reasons.joined(separator: "；"))
    }

    /// Autonomy actually granted: capped by what the artifact has earned and by current conditions.
    public static func effectiveAutonomy(_ a: ModelArtifact, _ d: DeviceProfile) -> AutonomyLevel {
        d.thermal >= .serious || d.lowPowerMode ? min(a.maxAutonomy, .restrictedTools) : a.maxAutonomy
    }
}

/// Keeps ASR, LLM and TTS from being resident together when they do not fit.
public struct ResidencyPlanner: Sendable {
    public struct Component: Sendable, Equatable { public var name: String; public var bytes: Int64; public var lastUsed: Date
        public init(name: String, bytes: Int64, lastUsed: Date) { self.name = name; self.bytes = bytes; self.lastUsed = lastUsed } }
    public enum PlanError: Error, Equatable, Sendable { case wontFit }
    public init() {}

    /// Returns the components to unload (least recently used first) so that `needed` fits within `budget`.
    public func unloads(resident: [Component], needed: Component, budget: Int64) throws -> [String] {
        var used = resident.reduce(0) { $0 + $1.bytes }
        var out: [String] = []
        for c in resident.sorted(by: { $0.lastUsed < $1.lastUsed }) where used + needed.bytes > budget {
            out.append(c.name); used -= c.bytes
        }
        guard used + needed.bytes <= budget else { throw PlanError.wontFit }
        return out
    }
}
