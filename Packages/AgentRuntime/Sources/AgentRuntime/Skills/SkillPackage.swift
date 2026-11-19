import Foundation
import CryptoKit

// Installable skills.
//
// An installed skill is DATA, never code: a SKILL.md (a name, a one-line description and instructions that teach the model how to use tools it
// already has) and, optionally, a skill.json that declares a few HTTPS calls as tools. Nothing a third party ships can run on the phone; the worst a
// skill can do is ask the model to call tools the person already has, or call the exact web hosts the person approved when installing it — and every
// such call is shown to the person for approval (reads of an approved host, with no secrets, excepted).
//
//   SKILL.md   ---\n name: …\n description: …\n version: 1.0.0\n id: …\n author: …\n category: …\n requires: tool_a, tool_b\n secrets: NAME\n runtime: 1\n ---\n instructions
//   skill.json { "tools": [ { "name", "description", "risk": "read|modify|external", "parameters": { "city": {"type":"string","description":"…","required":true} },
//                             "http": { "method": "GET|POST", "url": "https://host/path?q={city}", "headers": {"Accept":"application/json","X-API-Key":"{secret:KEY}"}, "body": "{…}" } } ] }
//   SKILL.sig  { "publisher": "…", "key": "<base64 Ed25519 public key>", "signature": "<base64 over the SHA-256 of the content>" }   (optional)

public enum SkillCategory: String, Codable, Sendable, CaseIterable {
    case productivity, communication, travel, health, home, learning, entertainment, developer, other
    public var title: String {
        switch self {
        case .productivity: "效率"; case .communication: "沟通"; case .travel: "出行"; case .health: "健康"; case .home: "家居"
        case .learning: "学习"; case .entertainment: "娱乐"; case .developer: "开发"; case .other: "其他"
        }
    }
}

/// Where a skill's words come from. Only `builtIn` and `user` text is the person's own; the rest is somebody else's text that is read like web content.
public enum SkillTrust: String, Codable, Sendable, Comparable {
    /// Shipped with iTalk.
    case builtIn
    /// Written by the person (instructions only; a skill with tools can never be this).
    case user
    /// From a file, link or paste; the publisher is unknown.
    case imported
    /// Signed by a publisher key the person pinned when installing; later updates must carry the same key.
    case verified
    public var isThirdParty: Bool { self == .imported || self == .verified }
    private var rank: Int { switch self { case .builtIn: 0; case .user: 1; case .verified: 2; case .imported: 3 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    public var title: String { switch self { case .builtIn: "内置"; case .user: "我自己的"; case .imported: "导入（来源未验证）"; case .verified: "已验证发布者" } }
}

public enum SkillPackageError: Error, Equatable, Sendable {
    case missingFrontMatter, missingField(String), invalidID(String), reservedID(String), tooLong(String), invalidVersion(String)
    case unsupportedRuntime(Int), tooManyTools, invalidTool(String), invalidURL(String), blockedHost(String), invalidHeader(String), invalidBody(String), undeclaredPlaceholder(String)
    case undeclaredSecret(String), unsupportedRisk(String), invalidSignature, publisherKeyChanged(String), hostsNotApproved([String]), notInstalled, nothingToRollBack
    case tooLarge, unreadable(String)
}

public struct SkillHTTPTool: Codable, Sendable, Equatable {
    public struct Param: Codable, Sendable, Equatable {
        public var type: ParamSpec.Kind
        public var description: String
        public var required: Bool
        public var enumValues: [String]?
        public var maxLength: Int?
        public var minimum: Double?
        public var maximum: Double?
    }
    public var name: String
    public var description: String
    public var parameters: [String: Param]
    /// What the author says the call does; the runtime may raise it (every POST needs approval) but never lowers it.
    public var risk: ToolRisk
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: String?
    public var host: String
    public var needsApproval: Bool { method != "GET" || risk != .read }
}

public struct SkillManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var author: String?
    public var category: SkillCategory
    public var instructions: String
    public var requires: [String]
    public var secrets: [String]
    public var tools: [SkillHTTPTool]
    public var hosts: [String] { Array(Set(tools.map(\.host))).sorted() }
}

/// A parsed, validated skill with the exact bytes it was parsed from (those bytes are what gets hashed, stored and signed).
public struct SkillPackage: Sendable, Equatable {
    public static let runtimeVersion = 1
    public static let maxInstructionCharacters = 8000, maxFileBytes = 200_000
    public var manifest: SkillManifest
    public var skillMD: Data
    public var toolsJSON: Data?
    public var signature: Data?
    public var warnings: [String]
    public var contentHash: String
    public var publisher: String?
    /// Set when a valid signature was present: the publisher key that signed this exact content.
    public var signedBy: Data?

    public static func hash(skillMD: Data, toolsJSON: Data?) -> Data {
        var h = SHA256(); h.update(data: skillMD); h.update(data: Data([0])); if let toolsJSON { h.update(data: toolsJSON) }
        return Data(h.finalize())
    }

    public static func parse(skillMD: Data, toolsJSON: Data? = nil, signature: Data? = nil, reservedIDs: Set<String> = []) throws -> SkillPackage {
        guard skillMD.count <= maxFileBytes, (toolsJSON?.count ?? 0) <= maxFileBytes else { throw SkillPackageError.tooLarge }
        guard let text = String(data: skillMD, encoding: .utf8) else { throw SkillPackageError.unreadable("SKILL.md 不是 UTF-8 文本") }
        let (fields, body) = try frontMatter(text)
        var warnings: [String] = []
        let known: Set<String> = ["name", "description", "version", "author", "category", "id", "requires", "secrets", "runtime"]
        for key in fields.keys.sorted() where !known.contains(key) { warnings.append("忽略了不支持的字段：\(key)") }
        guard let name = fields["name"].map { clean($0) }, !name.isEmpty else { throw SkillPackageError.missingField("name") }
        guard let description = fields["description"].map { clean($0) }, !description.isEmpty else { throw SkillPackageError.missingField("description") }
        guard name.count <= 40 else { throw SkillPackageError.tooLong("name") }
        guard description.count <= 120 else { throw SkillPackageError.tooLong("description") }
        let id = try fields["id"].map { try validID($0) } ?? derivedID(from: name)
        if reservedIDs.contains(id) || ["core", "memory", "skills", "system", "italk", "apple", "remote"].contains(id) { throw SkillPackageError.reservedID(id) }
        let version = fields["version"].map { clean($0) } ?? "1.0.0"
        guard version.range(of: #"^\d{1,4}(\.\d{1,4}){0,2}$"#, options: .regularExpression) != nil else { throw SkillPackageError.invalidVersion(version) }
        let runtime = fields["runtime"].flatMap { Int($0) } ?? 1
        guard runtime <= runtimeVersion else { throw SkillPackageError.unsupportedRuntime(runtime) }
        let category = fields["category"].flatMap { SkillCategory(rawValue: clean($0).lowercased()) } ?? .other
        if let c = fields["category"], SkillCategory(rawValue: clean(c).lowercased()) == nil { warnings.append("未知分类 \(c)，已归入「其他」") }
        let author = fields["author"].map { clean($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        let instructions = clean(body, keepNewlines: true)
        guard instructions.count <= maxInstructionCharacters else { throw SkillPackageError.tooLong("instructions") }
        let requires = list(fields["requires"]), secrets = list(fields["secrets"])
        guard secrets.count <= 3, secrets.allSatisfy({ $0.range(of: #"^[A-Z][A-Z0-9_]{1,31}$"#, options: .regularExpression) != nil }) else { throw SkillPackageError.undeclaredSecret(secrets.joined(separator: ",")) }
        guard requires.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil }) else { throw SkillPackageError.invalidTool("requires") }
        let tools = try toolsJSON.map { try parseTools($0, skillID: id, secrets: Set(secrets)) } ?? []
        let manifest = SkillManifest(id: id, name: name, summary: description, version: version, author: author, category: category, instructions: instructions,
                                     requires: requires, secrets: secrets, tools: tools)
        let digest = hash(skillMD: skillMD, toolsJSON: toolsJSON)
        var package = SkillPackage(manifest: manifest, skillMD: skillMD, toolsJSON: toolsJSON, signature: signature, warnings: warnings,
                                   contentHash: digest.map { String(format: "%02x", $0) }.joined(), publisher: nil, signedBy: nil)
        if let signature { try package.verify(signature: signature, digest: digest) }
        return package
    }

    private mutating func verify(signature raw: Data, digest: Data) throws {
        struct Sig: Decodable { var publisher: String; var key: String; var signature: String }
        guard let s = try? JSONDecoder().decode(Sig.self, from: raw), let key = Data(base64Encoded: s.key), let sig = Data(base64Encoded: s.signature),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key), pub.isValidSignature(sig, for: digest), !s.publisher.isEmpty, s.publisher.count <= 60 else { throw SkillPackageError.invalidSignature }
        publisher = Self.clean(s.publisher); signedBy = key
    }

    /// Key id shown to the person ("A1B2-C3D4-E5F6") so a publisher key can be recognised again.
    public static func keyFingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).map { String(format: "%02X", $0) }.joined().prefix(12)
        return stride(from: 0, to: 12, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }

    // MARK: Parsing helpers

    /// Removes characters that can hide instructions from a reader (zero-width, bidi overrides, control codes). Newlines stay when asked.
    static func clean(_ s: String, keepNewlines: Bool = false) -> String {
        let bad: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF, 0x00AD]
        let scalars = s.unicodeScalars.filter { u in
            if bad.contains(u.value) { return false }
            if u == "\n" || u == "\t" { return keepNewlines }
            return !(u.value < 0x20 || u.value == 0x7F)
        }
        var out = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if keepNewlines { while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") } }
        return out
    }

    private static func frontMatter(_ text: String) throws -> ([String: String], String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { throw SkillPackageError.missingFrontMatter }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("#") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { fields[key] = value }
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func list(_ s: String?) -> [String] { (s ?? "").split(whereSeparator: { ",，; ".contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    static func validID(_ raw: String) throws -> String {
        let id = clean(raw).lowercased()
        guard id.range(of: #"^[a-z][a-z0-9_]{2,31}$"#, options: .regularExpression) != nil, !id.contains("__") else { throw SkillPackageError.invalidID(raw) }
        return id
    }

    private static func derivedID(from name: String) throws -> String {
        let slug = name.lowercased().unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) ? Character($0) : "_" }
        var id = String(slug).replacingOccurrences(of: "_+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if id.count < 3 || !(id.first?.isLetter ?? false) { throw SkillPackageError.missingField("id") }
        id = String(id.prefix(32)); return try validID(id)
    }

    // MARK: skill.json

    private struct ToolFile: Decodable {
        struct Tool: Decodable {
            struct Param: Decodable { var type: String; var description: String?; var required: Bool?; var `enum`: [String]?; var maxLength: Int?; var minimum: Double?; var maximum: Double? }
            struct HTTP: Decodable { var method: String?; var url: String; var headers: [String: String]?; var body: String? }
            var name: String; var description: String; var parameters: [String: Param]?; var risk: String?; var http: HTTP
        }
        var tools: [Tool]
    }

    static let allowedHeaders: Set<String> = ["accept", "accept-language", "content-type", "authorization", "x-api-key", "x-auth-token", "api-key"]
    static let blockedSuffixes = [".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".intranet", ".private", ".test", ".invalid", ".example", ".onion"]

    private static func parseTools(_ data: Data, skillID: String, secrets: Set<String>) throws -> [SkillHTTPTool] {
        let file: ToolFile
        do { file = try JSONDecoder().decode(ToolFile.self, from: data) } catch { throw SkillPackageError.unreadable("skill.json 格式不正确") }
        guard file.tools.count <= 8 else { throw SkillPackageError.tooManyTools }
        var seen = Set<String>(), out: [SkillHTTPTool] = []
        for t in file.tools {
            let name = clean(t.name)
            guard name.range(of: #"^[a-z][a-z0-9_]{0,30}$"#, options: .regularExpression) != nil, !name.contains("__"), "\(skillID)__\(name)".count <= 64, seen.insert(name).inserted else { throw SkillPackageError.invalidTool(t.name) }
            let description = clean(t.description)
            guard !description.isEmpty, description.count <= 200 else { throw SkillPackageError.tooLong("tool description") }
            let rawParams = t.parameters ?? [:]
            guard rawParams.count <= 8 else { throw SkillPackageError.invalidTool("\(name): too many parameters") }
            var params: [String: SkillHTTPTool.Param] = [:]
            for (key, p) in rawParams {
                guard key.range(of: #"^[a-z][a-z0-9_]{0,30}$"#, options: .regularExpression) != nil, let kind = ParamSpec.Kind(rawValue: p.type), [.string, .number, .integer, .boolean].contains(kind) else { throw SkillPackageError.invalidTool("\(name).\(key)") }
                params[key] = .init(type: kind, description: String(clean(p.description ?? "").prefix(120)), required: p.required ?? true, enumValues: p.enum?.prefix(20).map { String(clean($0).prefix(40)) },
                                    maxLength: min(p.maxLength ?? 200, 500), minimum: p.minimum, maximum: p.maximum)
            }
            let method = (t.http.method ?? "GET").uppercased()
            guard ["GET", "POST"].contains(method) else { throw SkillPackageError.invalidTool("\(name): method") }
            let (host, _) = try validateURL(t.http.url, params: Set(params.keys))
            var declared: ToolRisk
            switch t.risk ?? (method == "GET" ? "read" : "external") {
            case "read": declared = .read
            case "modify": declared = .modify
            case "external": declared = .external
            default: throw SkillPackageError.unsupportedRisk(t.risk ?? "")
            }
            if method == "POST", declared == .read { declared = .modify }               // a POST can change something remotely: never presented as a read
            var headers: [String: String] = [:]
            for (k, v) in t.http.headers ?? [:] {
                guard allowedHeaders.contains(k.lowercased()), !v.contains("\n"), v.count <= 200 else { throw SkillPackageError.invalidHeader(k) }
                for m in v.matches(of: /\{([^{}]+)\}/) {
                    let inner = String(m.output.1)
                    guard inner.hasPrefix("secret:"), secrets.contains(String(inner.dropFirst(7))) else { throw SkillPackageError.undeclaredSecret(inner) }
                }
                headers[k] = v
            }
            var body = t.http.body
            if let b = body {
                guard method == "POST", b.count <= 2000 else { throw SkillPackageError.invalidBody(name) }
                for m in b.matches(of: /\{([a-z][a-z0-9_]*)\}/) where params[String(m.output.1)] == nil { throw SkillPackageError.undeclaredPlaceholder(String(m.output.1)) }
                let probe = b.replacing(/\{([a-z][a-z0-9_]*)\}/, with: "x")
                guard (try? JSONSerialization.jsonObject(with: Data(probe.utf8))) != nil else { throw SkillPackageError.invalidBody(name) }
            } else if method == "POST" { body = nil }
            out.append(SkillHTTPTool(name: name, description: description, parameters: params, risk: declared, method: method, url: t.http.url, headers: headers, body: body, host: host))
        }
        return out
    }

    /// https only, a real public-looking name (never an address, port, login or local name), placeholders only in the path and query.
    static func validateURL(_ raw: String, params: Set<String>) throws -> (host: String, template: String) {
        guard raw.count <= 500, raw.hasPrefix("https://") else { throw SkillPackageError.invalidURL(raw) }
        let afterScheme = raw.dropFirst("https://".count)
        let hostPart = String(afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !hostPart.contains("{"), !hostPart.contains("@"), !hostPart.contains(":"), !hostPart.isEmpty else { throw SkillPackageError.blockedHost(hostPart) }
        let host = hostPart.lowercased()
        guard host.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              host.split(separator: ".").last.map({ $0.contains(where: \.isLetter) }) ?? false,           // an all-numeric last label is an IP address
              !blockedSuffixes.contains(where: { host.hasSuffix($0) }), host != "localhost" else { throw SkillPackageError.blockedHost(host) }
        guard !raw.contains("#") else { throw SkillPackageError.invalidURL(raw) }
        for m in raw.matches(of: /\{([^{}]*)\}/) {
            let name = String(m.output.1)
            guard params.contains(name) else { throw SkillPackageError.undeclaredPlaceholder(name) }
        }
        let probe = raw.replacing(/\{[^{}]*\}/, with: "x")
        guard let url = URL(string: probe), url.scheme == "https", url.host?.lowercased() == host else { throw SkillPackageError.invalidURL(raw) }
        return (host, raw)
    }
}
