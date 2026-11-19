import Foundation
import CryptoKit

// Memory sync between the person's own devices, without an iTalk account.
//
// Each device writes ONE file of its own (a full, encrypted copy of its memory: items + deletions) into a place all of the person's devices can read
// (an iCloud Drive folder in the app; any folder in tests) and merges the files of the other devices into its own store. Because every file has exactly one
// writer, devices never overwrite each other's files, and the merge rules of `MemoryStore.merge` decide every conflict the same way on every device:
// the higher revision wins, a deletion beats any edit made before it, two devices that learned different values for the same slot keep the newer one.
// Offline is normal: nothing is lost, the next successful sync catches up. Files are sealed with AES-GCM using a key that never leaves the person's
// own Apple devices (iCloud Keychain); without that key nothing is uploaded or read.

public struct SyncFile: Sendable, Equatable {
    public var deviceId: String
    public var data: Data
    public var modifiedAt: Date
    public init(deviceId: String, data: Data, modifiedAt: Date) { self.deviceId = deviceId; self.data = data; self.modifiedAt = modifiedAt }
}

public enum SyncTransportError: Error, Sendable, Equatable {
    /// iCloud (or the folder) cannot be used right now: signed out, entitlement missing, container not ready.
    case unavailable(String)
    /// A file is still being downloaded by the system; try again later.
    case notDownloadedYet
}

public protocol SyncTransport: Sendable {
    func publish(deviceId: String, data: Data) async throws
    func fetchAll() async throws -> [SyncFile]
    func remove(deviceId: String) async throws
}

/// One file per device in a folder (the iCloud Drive container folder in the app, a temporary folder in tests).
public struct FolderSyncTransport: SyncTransport {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func url(_ deviceId: String) -> URL { directory.appendingPathComponent("memory-\(deviceId).sync") }

    public func publish(deviceId: String, data: Data) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(deviceId), options: .atomic)
    }
    public func fetchAll() async throws -> [SyncFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard name.hasPrefix("memory-"), name.hasSuffix(".sync") else { return nil }
            let id = String(name.dropFirst("memory-".count).dropLast(".sync".count))
            let u = directory.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: u) else { return nil }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return SyncFile(deviceId: id, data: d, modifiedAt: m)
        }
    }
    public func remove(deviceId: String) async throws { try? FileManager.default.removeItem(at: url(deviceId)) }
}

public protocol SyncCrypto: Sendable {
    func seal(_ plain: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

public enum SyncCryptoError: Error, Sendable, Equatable {
    case unreadable
    /// Sealed with a different key: another person's folder, or this person's other device whose key has not arrived through iCloud Keychain yet.
    case otherKey
}

/// AES-256-GCM with a random nonce. The file starts with a version tag and a 4-byte id of the key, so a file written with another key is told apart from a damaged one.
public struct AESGCMSyncCrypto: SyncCrypto {
    private let key: SymmetricKey
    private static let tag = Data("ITSY1".utf8)
    public init(key: SymmetricKey) { self.key = key }
    public init(keyData: Data) { self.key = SymmetricKey(data: keyData) }
    public static func newKeyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    private var keyId: Data { Data(SHA256.hash(data: key.withUnsafeBytes { Data($0) }).prefix(4)) }
    public func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw SyncCryptoError.unreadable }
        return Self.tag + keyId + combined
    }
    public func open(_ sealed: Data) throws -> Data {
        guard sealed.starts(with: Self.tag), sealed.count > Self.tag.count + 4 else { throw SyncCryptoError.unreadable }
        let id = sealed.dropFirst(Self.tag.count).prefix(4)
        guard Data(id) == keyId else { throw SyncCryptoError.otherKey }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.dropFirst(Self.tag.count + 4)), using: key) } catch { throw SyncCryptoError.unreadable }
    }
}

struct MemorySyncSnapshot: Codable {
    var version = 1
    var deviceId: String
    var items: [MemoryItem]
    var tombstones: [MemoryTombstone]
}

public actor MemorySyncEngine {
    public struct Report: Sendable, Equatable {
        public var published = false
        public var devicesSeen = 0
        /// Items added or replaced from other devices, plus items removed by their deletions.
        public var changedLocally = 0
        public var slotConflictsResolved = 0
        /// Files that could not be read (corrupt, newer format): skipped, never fatal.
        public var unreadableFiles = 0
        /// Files sealed with another key: someone else's data, or this person's other device before its key arrived (iCloud Keychain).
        public var otherKeyFiles = 0
        public var error: String?
    }
    public enum State: Sendable, Equatable { case idle, syncing, synced(Date), offline(String) }

    private let store: MemoryStore, transport: SyncTransport, crypto: SyncCrypto, deviceId: String
    private var lastPublishedFingerprint: String?
    public private(set) var state: State = .idle
    private var listener: UUID?
    private var debounce: Task<Void, Never>?

    public init(store: MemoryStore, transport: SyncTransport, crypto: SyncCrypto, deviceId: String) {
        self.store = store; self.transport = transport; self.crypto = crypto; self.deviceId = deviceId
    }

    /// One full round: read the other devices, merge, settle conflicts, publish this device's copy if it changed.
    @discardableResult
    public func sync() async -> Report {
        state = .syncing
        var report = Report()
        do {
            let files = try await transport.fetchAll()
            let beforeExport = await store.export()
            let before = fingerprint(of: beforeExport)
            let beforeKeys = Set(beforeExport.items.map { "\($0.id)/\($0.revision)" } + beforeExport.tombstones.map { "t\($0.id)" })
            for file in files where file.deviceId != deviceId {
                do {
                    let snapshot = try JSONDecoder.sync.decode(MemorySyncSnapshot.self, from: try crypto.open(file.data))
                    guard snapshot.version == 1 else { report.unreadableFiles += 1; continue }
                    try await store.merge(items: snapshot.items, tombstones: snapshot.tombstones)
                    report.devicesSeen += 1
                } catch SyncCryptoError.otherKey { report.otherKeyFiles += 1 }
                catch { report.unreadableFiles += 1 }
            }
            report.slotConflictsResolved = (try? await store.resolveSlotConflicts()) ?? 0
            let after = await store.export()
            let afterKeys = Set(after.items.map { "\($0.id)/\($0.revision)" } + after.tombstones.map { "t\($0.id)" })
            report.changedLocally = afterKeys.symmetricDifference(beforeKeys).count
            // Publish when this device's content changed since its last published copy (or was never published).
            let fp = fingerprint(of: after)
            if fp != lastPublishedFingerprint {
                let plain = try JSONEncoder.sync.encode(MemorySyncSnapshot(deviceId: deviceId, items: after.items, tombstones: after.tombstones))
                try await transport.publish(deviceId: deviceId, data: try crypto.seal(plain))
                lastPublishedFingerprint = fp; report.published = true
            }
            state = .synced(Date())
        } catch {
            report.error = "\(error)"; state = .offline("\(error)")
        }
        return report
    }

    /// Syncs once now, then again shortly after every local change (batched), so edits reach the other devices without any button.
    public func start() async {
        guard listener == nil else { return }
        let engine = self
        listener = await store.addListener { Task { await engine.scheduleSync() } }
        await sync()
    }
    public func stop() async { if let l = listener { await store.removeListener(l) }; listener = nil; debounce?.cancel() }

    private func scheduleSync() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Stops syncing and removes this device's file (the other devices keep their own copies).
    public func leave() async { await stop(); try? await transport.remove(deviceId: deviceId); lastPublishedFingerprint = nil }

    private func fingerprint(of e: (items: [MemoryItem], tombstones: [MemoryTombstone])) -> String {
        var h = SHA256()
        for i in e.items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { h.update(data: Data("\(i.id)|\(i.revision)|\(i.updatedAt.timeIntervalSince1970)|\(i.text)|\(i.pinned)|\(i.kind.rawValue)".utf8)) }
        for t in e.tombstones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { h.update(data: Data("T\(t.id)|\(t.revision)|\(t.deletedAt.timeIntervalSince1970)".utf8)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder { static var sync: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]; return e } }
extension JSONDecoder { static var sync: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d } }

#if os(iOS)
/// The app's iCloud Drive container as a folder of device files. Needs the iCloud Documents capability on the app (entitlement
/// `com.apple.developer.ubiquity-container-identifiers`); until it is added, `available()` reports why and nothing is synced.
public struct ICloudDriveSyncTransport: SyncTransport {
    public let containerIdentifier: String?
    public init(containerIdentifier: String? = nil) { self.containerIdentifier = containerIdentifier }

    public func available() -> Result<URL, SyncTransportError> {
        guard FileManager.default.ubiquityIdentityToken != nil else { return .failure(.unavailable("未登录 iCloud，或已关闭 iCloud 云盘。")) }
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else { return .failure(.unavailable("这个 App 尚未获得 iCloud 云盘权限。")) }
        return .success(root.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Sync", isDirectory: true))
    }
    private func folder() throws -> FolderSyncTransport {
        switch available() { case .success(let url): return FolderSyncTransport(directory: url); case .failure(let e): throw e }
    }
    public func publish(deviceId: String, data: Data) async throws {
        let target = try folder()
        let url = target.directory.appendingPathComponent("memory-\(deviceId).sync")
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
    public func fetchAll() async throws -> [SyncFile] {
        let target = try folder()
        // Files from other devices may only exist as ".name.icloud" placeholders: ask the system to download them and try again on the next round.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: target.directory.path) {
            for name in names where name.hasSuffix(".icloud") { try? FileManager.default.startDownloadingUbiquitousItem(at: target.directory.appendingPathComponent(name)) }
        }
        return try await target.fetchAll()
    }
    public func remove(deviceId: String) async throws { try await folder().remove(deviceId: deviceId) }
}
#endif
