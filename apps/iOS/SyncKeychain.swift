import Foundation
import Security
import AgentRuntime

/// The key that seals memory files in iCloud Drive. It is a synchronizable Keychain item (iCloud Keychain), so it reaches the person's other devices
/// end to end and never travels through iTalk or Apple's servers in the clear; without it nothing can be read.
enum SyncKeychain {
    private static let service = "com.italk.sync", account = "memory-v1"

    static func key() -> Data? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecAttrSynchronizable as String: kCFBooleanTrue as Any]
        var found: CFTypeRef?
        if SecItemCopyMatching(base.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found) == errSecSuccess, let data = found as? Data { return data }
        let fresh = AESGCMKey.random()
        let add = base.merging([kSecValueData as String: fresh, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }

    /// Stable per installation (not synchronized): names this device's file in the shared folder.
    static func deviceId() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-id", kSecReturnData as String: true]
        var found: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let data = found as? Data, let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16).description
        _ = SecItemAdd(q.merging([kSecValueData as String: Data(id.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }.filter { $0.key != kSecReturnData as String } as CFDictionary, nil)
        return id
    }
}

private enum AESGCMKey {
    static func random() -> Data { AESGCMSyncCrypto.newKeyData() }
}
