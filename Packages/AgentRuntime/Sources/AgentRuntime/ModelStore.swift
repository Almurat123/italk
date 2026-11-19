import Foundation
import CryptoKit

public struct InstalledModel: Codable, Sendable, Equatable { public var id: String; public var version: String; public var bytes: Int64; public var installedAt: Date }

public enum ModelStoreError: Error, Equatable, Sendable {
    case integrityFailure(file: String), sizeMismatch(file: String), notInstalled
    case insufficientStorage(neededBytes: Int64)
    case noSources
    /// Every source failed for `file`. `reasons` maps source id → short reason, for the UI and diagnostics.
    case allSourcesFailed(file: String, reasons: [String: String])
    case importMissing(file: String)
}

public enum DownloadState: Sendable, Equatable {
    case queued
    case downloading(file: String, fraction: Double, source: String)
    case switchingSource(from: String, reason: String)
    case verifying(file: String)
    case installed
    case failed(String)
}

/// On-disk model library. Files are staged in `partial/`, each must match the manifest size and SHA-256, and only then is the
/// whole model moved into `models/` atomically. A failed or interrupted download never becomes an installed model.
public actor ModelStore {
    public let root: URL
    private var manifest: [String: InstalledModel] = [:]
    private let manifestURL: URL
    private let session: URLSession
    private let freeSpace: @Sendable () -> Int64
    /// Retries per source before moving to the next one; backoff in seconds for each retry.
    public var retryBackoff: [Double] = [1, 3]
    public var requestTimeout: TimeInterval = 30

    public init(root: URL, session: URLSession = .shared, freeSpace: (@Sendable () -> Int64)? = nil) throws {
        self.root = root; self.session = session; self.manifestURL = root.appendingPathComponent("manifest.json")
        let r = root
        self.freeSpace = freeSpace ?? { (try? r.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("partial"), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: manifestURL), let m = try? AgentCoding.decoder().decode([String: InstalledModel].self, from: d) { manifest = m }
    }

    public func setRetryBackoff(_ b: [Double]) { retryBackoff = b }

    public func installed() -> [InstalledModel] { manifest.values.sorted { $0.id < $1.id } }
    public func directory(for id: String) -> URL? { manifest[id] != nil ? root.appendingPathComponent("models/\(id)") : nil }
    public func isInstalled(_ a: ModelArtifact) -> Bool { manifest[a.id]?.version == a.version }
    public func partialBytes() -> Int64 { Self.size(of: root.appendingPathComponent("partial")) }
    /// Bytes already on disk for an unfinished download of `a` (shown as "continue" progress).
    public func partialBytes(for a: ModelArtifact) -> Int64 { Self.size(of: stage(a)) }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stage(_ a: ModelArtifact) -> URL { root.appendingPathComponent("partial/\(a.id)-\(a.version)") }

    /// Downloads every file from the ordered `sources`, failing over per file. Partial bytes survive interruption and are
    /// resumed with HTTP Range from whichever source is tried next. Corrupt data is deleted and that source is skipped.
    public func install(_ artifact: ModelArtifact, sources: [ModelSource], onState: @escaping @Sendable (DownloadState) -> Void = { _ in }) async throws {
        guard !sources.isEmpty else { throw ModelStoreError.noSources }
        let stage = stage(artifact)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        onState(.queued)
        let total = Double(artifact.totalBytes)
        var badSources = Set<String>()
        for (i, file) in artifact.files.enumerated() {
            try Task.checkCancellation()
            let dest = stage.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if Self.fileSize(dest) == file.bytes, (try? Self.sha256(of: dest)) == file.sha256 { continue }   // verified earlier
            try? FileManager.default.removeItem(at: dest)
            let part = dest.appendingPathExtension("part")
            // Storage: remaining bytes for this and later files, plus headroom.
            let remaining = artifact.files[i...].reduce(Int64(0)) { $0 + $1.bytes } - Self.fileSize(part)
            if freeSpace() < remaining + 200_000_000 { throw ModelStoreError.insufficientStorage(neededBytes: remaining + 200_000_000) }

            let before = artifact.files[..<i].reduce(Int64(0)) { $0 + $1.bytes }
            var reasons: [String: String] = [:]
            var done = false
            for source in sources where !badSources.contains(source.id) && !done {
                guard let url = source.url(for: file.remotePath, artifact: artifact) else { reasons[source.id] = "bad url"; continue }
                for attempt in 0...retryBackoff.count {
                    try Task.checkCancellation()
                    if attempt > 0 { try await Task.sleep(for: .seconds(retryBackoff[attempt - 1])) }
                    onState(.downloading(file: file.name, fraction: (Double(before) + Double(Self.fileSize(part))) / total, source: source.id))
                    do {
                        let src = source.id
                        try await RangeDownloader().fetch(url, part: part, expectedTotal: file.bytes, session: session, timeout: requestTimeout) { n in
                            onState(.downloading(file: file.name, fraction: min(1, (Double(before) + Double(n)) / total), source: src))
                        }
                    } catch is CancellationError {
                        throw CancellationError()                 // keep the .part for the next attempt
                    } catch RangeDownloader.Failure.http(let code) where (400..<500).contains(code) && code != 408 && code != 429 {
                        if code == 416 { try? FileManager.default.removeItem(at: part) }
                        reasons[source.id] = "HTTP \(code)"; break   // not retryable on this source
                    } catch RangeDownloader.Failure.rangeMismatch {
                        try? FileManager.default.removeItem(at: part); reasons[source.id] = "range mismatch"; continue
                    } catch RangeDownloader.Failure.tooLarge {
                        try? FileManager.default.removeItem(at: part); badSources.insert(source.id); reasons[source.id] = "larger than manifest"; break
                    } catch {
                        reasons[source.id] = "\(error)"; continue       // network: retry, then next source, part kept
                    }
                    guard Self.fileSize(part) == file.bytes else { reasons[source.id] = "incomplete"; continue }
                    onState(.verifying(file: file.name))
                    if try Self.sha256(of: part) == file.sha256 {
                        try FileManager.default.moveItem(at: part, to: dest); done = true; break
                    }
                    // Wrong bytes: never trust this source again for this install; restart the file elsewhere.
                    try? FileManager.default.removeItem(at: part)
                    badSources.insert(source.id); reasons[source.id] = "hash mismatch"
                    break
                }
                if !done, let r = reasons[source.id] { onState(.switchingSource(from: source.id, reason: r)) }
            }
            if !done { throw ModelStoreError.allSourcesFailed(file: file.name, reasons: reasons) }
        }
        try commit(artifact, from: stage)
        onState(.installed)
    }

    /// Development / offline testing: install from a folder that already contains the model files (e.g. copied with
    /// Files or devicectl). Every file is size- and hash-checked against the manifest exactly like a download.
    public func importPackage(_ artifact: ModelArtifact, from folder: URL) throws {
        let stage = stage(artifact)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for file in artifact.files {
            let src = folder.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: src.path) else { try? FileManager.default.removeItem(at: stage); throw ModelStoreError.importMissing(file: file.name) }
            guard Self.fileSize(src) == file.bytes else { try? FileManager.default.removeItem(at: stage); throw ModelStoreError.sizeMismatch(file: file.name) }
            guard try Self.sha256(of: src) == file.sha256 else { try? FileManager.default.removeItem(at: stage); throw ModelStoreError.integrityFailure(file: file.name) }
            let dest = stage.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dest)
        }
        try commit(artifact, from: stage)
    }

    private func commit(_ artifact: ModelArtifact, from stage: URL) throws {
        let final = root.appendingPathComponent("models/\(artifact.id)")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: stage, to: final)
        var values = URLResourceValues(); values.isExcludedFromBackup = true      // re-downloadable; keep out of iCloud backup
        var u = final; try? u.setResourceValues(values)
        manifest[artifact.id] = InstalledModel(id: artifact.id, version: artifact.version, bytes: artifact.totalBytes, installedAt: .now)
        try saveManifest()
    }

    /// Cheap launch-time check (sizes only). A damaged install is removed so the UI offers a fresh download.
    @discardableResult
    public func validateInstalled(_ artifact: ModelArtifact) -> Bool {
        guard let dir = directory(for: artifact.id) else { return false }
        let ok = artifact.files.allSatisfy { Self.fileSize(dir.appendingPathComponent($0.name)) == $0.bytes }
        if !ok { try? remove(artifact.id) }
        return ok
    }

    /// Full re-hash of installed files.
    public func verify(_ artifact: ModelArtifact) throws -> Bool {
        guard let dir = directory(for: artifact.id) else { throw ModelStoreError.notInstalled }
        return try artifact.files.allSatisfy { try Self.sha256(of: dir.appendingPathComponent($0.name)) == $0.sha256 }
    }

    @discardableResult
    public func remove(_ id: String) throws -> Int64 {
        guard let m = manifest[id] else { throw ModelStoreError.notInstalled }
        try FileManager.default.removeItem(at: root.appendingPathComponent("models/\(id)"))
        manifest[id] = nil; try saveManifest()
        return m.bytes
    }

    public func clearPartialDownloads() throws {
        let dir = root.appendingPathComponent("partial")
        for u in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: u) }
    }

    private func saveManifest() throws { try AgentCoding.encoder().encode(manifest).write(to: manifestURL, options: .atomic) }

    /// Uncached on purpose: URL.resourceValues caches per URL instance and would report a stale size mid-download.
    static func fileSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    static func size(of dir: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let u = e?.nextObject() as? URL { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

