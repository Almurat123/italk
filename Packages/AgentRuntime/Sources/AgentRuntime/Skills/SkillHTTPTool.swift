import Foundation

// The only "code" an installed skill can have: a declared HTTPS call. The runtime builds the request itself from the declaration and the model's
// (validated) arguments; the author's text never becomes a URL host, a header name or anything executed.

public struct SkillHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
}

public struct SkillHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    public var body: Data
    public init(status: Int, contentType: String?, body: Data) { self.status = status; self.contentType = contentType; self.body = body }
}

public protocol SkillHTTPClient: Sendable {
    /// Must refuse to leave `host` (including through redirects) and must stop reading after about 64 KB.
    func send(_ request: SkillHTTPRequest, host: String) async throws -> SkillHTTPResponse
}

public protocol SkillSecretStore: Sendable {
    func get(skill: String, name: String) -> String?
    func set(skill: String, name: String, value: String)
    func removeAll(skill: String)
}

public final class InMemorySkillSecrets: SkillSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func get(skill: String, name: String) -> String? { lock.withLock { values["\(skill)/\(name)"] } }
    public func set(skill: String, name: String, value: String) { lock.withLock { values["\(skill)/\(name)"] = value } }
    public func removeAll(skill: String) { lock.withLock { values = values.filter { !$0.key.hasPrefix("\(skill)/") } } }
}

enum SkillHTTPRender {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func text(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: ""
        }
    }

    /// Every `{param}` becomes the percent-encoded value; nothing the model sends can add a path segment, a query parameter or change the host.
    static func url(_ template: String, values: [String: JSONValue]) -> String {
        template.replacing(/\{([a-z][a-z0-9_]*)\}/) { m in
            let t = text(values[String(m.output.1)] ?? .null)
            // "." and ".." are unreserved but are path segments: encode them so a value can never walk up the path.
            if !t.isEmpty, t.allSatisfy({ $0 == "." }) { return t.replacingOccurrences(of: ".", with: "%2E") }
            return t.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
    }

    /// JSON string content: quotes, backslashes and control characters escaped, so a value can never close the string it is placed in.
    static func jsonEscaped(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
    static func body(_ template: String, values: [String: JSONValue]) -> String {
        template.replacing(/\{([a-z][a-z0-9_]*)\}/) { m in
            let v = values[String(m.output.1)] ?? .null
            if case .string(let s) = v { return jsonEscaped(s) }
            if case .null = v { return "null" }                 // an omitted optional value stays valid JSON
            return text(v)
        }
    }
}

public struct SkillHTTPAgentTool: AgentTool {
    public let spec: ToolSpec
    let skillId: String, skillName: String, tool: SkillHTTPTool, secrets: SkillSecretStore, client: SkillHTTPClient

    public init(skillId: String, skillName: String, tool: SkillHTTPTool, secrets: SkillSecretStore, client: SkillHTTPClient) {
        self.skillId = skillId; self.skillName = skillName; self.tool = tool; self.secrets = secrets; self.client = client
        var params: [String: ParamSpec] = [:]
        for (k, p) in tool.parameters {
            params[k] = ParamSpec(p.type, p.description, required: p.required, enumValues: p.enumValues, maxLength: p.type == .string ? p.maxLength : nil, minimum: p.minimum, maximum: p.maximum)
        }
        // Reads of an approved host that use no secret run directly; everything else is shown to the person first, every time.
        let direct = !tool.needsApproval && !tool.headers.values.contains { $0.contains("{secret:") }
        spec = ToolSpec(name: "\(skillId)__\(tool.name)", description: "\(tool.description)（第三方技能「\(skillName)」）", parameters: params,
                        permission: direct ? .readOnly : .confirmBeforeAction, capability: .thirdPartySkills, dataClass: .general, timeoutSeconds: 15)
    }

    public func describe(_ arguments: JSONValue) -> String {
        let shown = (arguments.objectValue ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\(SkillHTTPRender.text($0.value).prefix(60))" }.joined(separator: "，")
        return "向 \(tool.host) 发送请求（第三方技能「\(skillName)」：\(tool.description)）" + (shown.isEmpty ? "" : "；内容：\(shown)")
    }

    public func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let values = arguments.objectValue ?? [:]
        guard let url = URL(string: SkillHTTPRender.url(tool.url, values: values)), url.scheme == "https", url.host?.lowercased() == tool.host, url.user == nil, url.port == nil else {
            throw ToolFailure("请求地址无效", retryable: false)
        }
        var headers: [String: String] = ["User-Agent": "iTalk-Skill/1", "Accept": "application/json, text/plain;q=0.8"]
        for (k, v) in tool.headers {
            var value = v
            for m in v.matches(of: /\{secret:([A-Z][A-Z0-9_]*)\}/) {
                guard let secret = secrets.get(skill: skillId, name: String(m.output.1)), !secret.isEmpty else { throw ToolFailure("缺少技能需要的密钥 \(m.output.1)，请在技能设置中填写。", retryable: false) }
                guard !secret.contains("\n"), !secret.contains("\r") else { throw ToolFailure("密钥格式无效", retryable: false) }
                value = value.replacingOccurrences(of: String(m.output.0), with: secret)
            }
            headers[k] = value
        }
        var body: Data?
        if tool.method == "POST" {
            body = tool.body.map { Data(SkillHTTPRender.body($0, values: values).utf8) } ?? Data("{}".utf8)
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "application/json" }
        }
        let response = try await client.send(SkillHTTPRequest(method: tool.method, url: url, headers: headers, body: body, timeout: 15), host: tool.host)
        guard (200..<300).contains(response.status) else { throw ToolFailure("服务返回了错误（\(response.status)）", retryable: response.status >= 500) }
        let type = (response.contentType ?? "").lowercased()
        guard type.isEmpty || type.contains("json") || type.hasPrefix("text/") else { throw ToolFailure("服务返回了不支持的内容类型", retryable: false) }
        let text = SkillPackage.clean(String(decoding: response.body.prefix(65_536), as: UTF8.self), keepNewlines: true)
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        return ToolOutput(value: .object(["status": .number(Double(response.status)), parsed != nil ? "data" : "text": parsed ?? .string(String(text.prefix(4000)))]),
                          summary: "「\(skillName)」返回了 \(response.body.count) 字节")
    }
}

public extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
}

/// Production client: no cookies, no cache, https only, redirects only inside the approved host, at most ~64 KB read.
public final class URLSessionSkillHTTPClient: NSObject, SkillHTTPClient, @unchecked Sendable {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCache = nil; c.httpShouldSetCookies = false; c.waitsForConnectivity = false; c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()
    public override init() { super.init() }

    public func send(_ request: SkillHTTPRequest, host: String) async throws -> SkillHTTPResponse {
        var r = URLRequest(url: request.url, timeoutInterval: request.timeout)
        r.httpMethod = request.method; r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: r, delegate: HostGuard(host: host))
        var data = Data()
        for try await b in bytes { data.append(b); if data.count > 65_536 { break } }
        guard let http = response as? HTTPURLResponse else { throw ToolFailure("服务没有返回有效内容", retryable: true) }
        return SkillHTTPResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
    }

    private final class HostGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let host: String
        init(host: String) { self.host = host }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" && request.url?.host?.lowercased() == host ? request : nil)
        }
    }
}
