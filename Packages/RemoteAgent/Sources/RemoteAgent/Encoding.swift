import Foundation
import CryptoKit

extension Data {
    init?(base64URL string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
