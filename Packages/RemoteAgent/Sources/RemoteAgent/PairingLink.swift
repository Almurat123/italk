import Foundation

/// What the QR code on the computer says: who the computer is, how to recognise its certificate, where to find it, and a one-time secret.
public struct RemotePairingLink: Sendable, Equatable {
    public enum ParseError: Error, Sendable, Equatable { case notAPairingLink, unsupportedVersion, malformed }

    public let agentKey: Data
    public let certificatePin: String
    public let pairingId: String
    public let secret: String
    public let name: String
    /// `host:port`, in the order the computer listed them (its `.local` name first, then LAN addresses, then any public address).
    public let endpoints: [String]

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), comps.scheme == "italk-pair" else { throw ParseError.notAPairingLink }
        guard comps.host == "v1" else { throw ParseError.unsupportedVersion }
        let items = comps.queryItems ?? []
        func one(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let k = one("k"), let key = Data(base64URL: k), key.count == 32, let pin = one("p"), pin.count == 43, let id = one("i"), !id.isEmpty, let secret = one("s"), !secret.isEmpty else { throw ParseError.malformed }
        let endpoints = items.filter { $0.name == "e" }.compactMap(\.value).filter { $0.contains(":") && !$0.contains("/") }
        guard !endpoints.isEmpty else { throw ParseError.malformed }
        self.agentKey = key; self.certificatePin = pin; self.pairingId = id; self.secret = secret
        self.name = (one("n") ?? "").isEmpty ? "Mac" : one("n")!
        self.endpoints = endpoints
    }

    public var agentId: String { RemoteIdentity.deviceId(for: agentKey) }
    public var fingerprint: String { RemoteIdentity.fingerprint(of: agentKey) }
}
