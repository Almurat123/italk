import Foundation
import Security
import AgentRuntime

/// Keys that third-party skills ask for (API keys). Stored in the Keychain on this device only, never shown to any model and never written to logs.
struct KeychainSkillSecrets: SkillSecretStore {
    private let service = "com.italk.skill-secrets"
    private func query(_ skill: String, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "\(skill)/\(name)"]
    }
    func get(skill: String, name: String) -> String? {
        var found: CFTypeRef?
        guard SecItemCopyMatching(query(skill, name).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found) == errSecSuccess, let d = found as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func set(skill: String, name: String, value: String) {
        let q = query(skill, name), data = Data(value.utf8)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 } as CFDictionary, nil)
        }
    }
    func removeAll(skill: String) {
        var found: CFTypeRef?
        let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        guard SecItemCopyMatching(all as CFDictionary, &found) == errSecSuccess, let rows = found as? [[String: Any]] else { return }
        for row in rows { if let account = row[kSecAttrAccount as String] as? String, account.hasPrefix("\(skill)/") { SecItemDelete(query(skill, String(account.dropFirst(skill.count + 1))) as CFDictionary) } }
    }
}
