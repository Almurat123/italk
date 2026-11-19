import Foundation
import CryptoKit

/// Identities are derived from public keys exactly as the Mac agent does it, so both sides show the same short codes.
public enum RemoteIdentity {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// First 80 bits of SHA-256(public key) in lowercase base32 (16 characters).
    public static func deviceId(for publicKey: Data) -> String {
        let digest = Array(SHA256.hash(data: publicKey).prefix(10))
        var out = "", buffer = 0, bits = 0
        for byte in digest {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
        }
        return out
    }

    /// "A1B2-C3D4-E5F6": what both screens show so the person can compare them.
    public static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).map { String(format: "%02X", $0) }.joined().prefix(12)
        return stride(from: 0, to: 12, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }
}

public protocol RemoteSecretStore: Sendable {
    func load(_ account: String) -> Data?
    func save(_ data: Data, account: String) throws
    func delete(_ account: String)
}

public final class InMemorySecretStore: RemoteSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func load(_ account: String) -> Data? { lock.withLock { values[account] } }
    public func save(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    public func delete(_ account: String) { lock.withLock { values[account] = nil } }
}

/// This phone's long-term signing key. The private half never leaves the secret store; the Mac only ever sees the public half.
public struct PhoneIdentity: @unchecked Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey
    public static let account = "remote.phone.identity.v1"

    public init(privateKey: Curve25519.Signing.PrivateKey) { self.privateKey = privateKey }

    public static func loadOrCreate(in store: RemoteSecretStore) throws -> PhoneIdentity {
        if let raw = store.load(account), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return PhoneIdentity(privateKey: key) }
        let key = Curve25519.Signing.PrivateKey()
        try store.save(key.rawRepresentation, account: account)
        return PhoneIdentity(privateKey: key)
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var deviceId: String { RemoteIdentity.deviceId(for: publicKey) }
    public var fingerprint: String { RemoteIdentity.fingerprint(of: publicKey) }
    public func sign(_ message: Data) throws -> Data { try privateKey.signature(for: message) }
}
