import Foundation
import CryptoKit
import Security

/// A URLSession that trusts exactly one certificate: the one whose SHA-256 was in the QR code. There is no certificate authority involved,
/// so a computer on the same network that is not the one the person paired with cannot impersonate it.
public final class PinnedSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let pin: String
    private let lock = NSLock()
    private var mismatch = false
    private var _session: URLSession?

    public init(pin: String) { self.pin = pin }

    public var session: URLSession {
        lock.withLock {
            if let s = _session { return s }
            let c = URLSessionConfiguration.ephemeral
            c.waitsForConnectivity = false
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 24 * 3600
            c.httpCookieStorage = nil; c.urlCache = nil; c.httpShouldSetCookies = false
            c.tlsMinimumSupportedProtocolVersion = .TLSv12
            let s = URLSession(configuration: c, delegate: self, delegateQueue: nil)
            _session = s
            return s
        }
    }

    /// True once a connection was refused because the certificate did not match; cleared when read.
    public func takeMismatch() -> Bool { lock.withLock { let m = mismatch; mismatch = false; return m } }

    public func invalidate() { lock.withLock { _session?.invalidateAndCancel(); _session = nil } }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = Data(SHA256.hash(data: der)).base64URLString
        if Self.constantTimeEqual(actual, pin) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { lock.withLock { mismatch = true }; completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Incremental Server-Sent Events parser. `AsyncBytes.lines` drops blank lines (which are the event separators), so bytes are split here.
struct SSEParser {
    struct Event: Sendable, Equatable { var id: Int?; var name: String; var data: String }
    private var line = [UInt8]()
    private var id: Int?, name = "message", data: [String] = []

    mutating func feed(_ byte: UInt8) -> Event? {
        if byte == 0x0A {
            defer { line.removeAll(keepingCapacity: true) }
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                guard !data.isEmpty || id != nil else { return nil }
                let event = Event(id: id, name: name, data: data.joined(separator: "\n"))
                id = nil; name = "message"; data = []
                return event
            }
            guard line.first != 0x3A else { return nil }                      // comment / keep-alive
            let text = String(decoding: line, as: UTF8.self)
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0]), value = parts.count > 1 ? String(parts[1].drop { $0 == " " }) : ""
            switch field {
            case "id": id = Int(value)
            case "event": name = value
            case "data": data.append(value)
            default: break
            }
            return nil
        }
        line.append(byte)
        return nil
    }
}
