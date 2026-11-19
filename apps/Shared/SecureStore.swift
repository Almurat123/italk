import Foundation
import CryptoKit
import Security
import AssistantCore

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum KeychainStore {
    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.italk.private", kSecAttrAccount as String: account, kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    /// `afterFirstUnlock`: readable while the phone is locked (a cloud run resumed in the background needs its session token).
    static func write(_ data: Data, account: String, afterFirstUnlock: Bool = false) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.italk.private", kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: afterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AppFailure.message("无法安全保存凭证。") }
        } else if status != errSecSuccess { throw AppFailure.message("设备锁定或凭证存储不可用。") }
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.italk.private", kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct Preferences: Codable {
    var endpoint = ""
    var speakResponses = true
    var autoListen = true
    var receipts: [Consent] = []
    var grantSet: Set<Scope> { Set(receipts.filter(\.granted).map(\.scope)) }
    mutating func set(_ scope: Scope, _ allowed: Bool) {
        receipts.removeAll { $0.scope == scope }
        receipts.append(Consent(scope: scope, granted: allowed))
    }
}

struct PrivateArchive: Codable {
    var preferences = Preferences()
    var memories: [MemoryRecord] = []
    var history: [HistoryEntry] = []
    var actionOutcomes: [String: String] = [:]
}

@MainActor final class SecureArchive {
    let url: URL
    init() throws {
        let previousExport = URL.temporaryDirectory.appending(path: "iTalk-export", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: previousExport.path) { try FileManager.default.removeItem(at: previousExport) }
        let directory = URL.applicationSupportDirectory.appending(path: "iTalk", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        url = directory.appending(path: "private.aes")
    }
    private func key() throws -> SymmetricKey {
        if let data = KeychainStore.read("archive-key") { return SymmetricKey(data: data) }
        if FileManager.default.fileExists(atPath: url.path) { throw AppFailure.message("私人数据暂不可访问，请解锁设备后重试。") }
        let key = SymmetricKey(size: .bits256)
        try KeychainStore.write(key.withUnsafeBytes { Data($0) }, account: "archive-key")
        return key
    }
    func load() throws -> PrivateArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return PrivateArchive() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try JSONDecoder().decode(PrivateArchive.self, from: AES.GCM.open(sealed, using: key()))
    }
    func save(_ archive: PrivateArchive) throws {
        let data = try JSONEncoder().encode(archive)
        let sealed = try AES.GCM.seal(data, using: key())
        guard let combined = sealed.combined else { throw AppFailure.message("无法加密私人数据。") }
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
    }
    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        KeychainStore.delete("archive-key"); KeychainStore.delete("gateway-token")
    }
}
