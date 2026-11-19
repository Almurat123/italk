import Foundation

/// A failure reported by the iTalk gateway (`{"error":{"code":…}}`) or by the network on the way to it.
public struct CloudAPIError: Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var status: Int
    public var detail: JSONValue?
    public init(code: String, status: Int, detail: JSONValue? = nil) { self.code = code; self.status = status; self.detail = detail }
    public var errorDescription: String? { Self.message(for: code) }
    /// The connection itself failed (offline, dropped, timed out): safe to retry with the same idempotency key.
    public var isNetwork: Bool { status == 0 }

    public static func message(for code: String) -> String {
        switch code {
        case "unauthorized": "登录已过期，请重新登录。"
        case "invalid_credentials": "邮箱或密码不正确。"
        case "email_taken": "这个邮箱已经注册。"
        case "invalid_email": "邮箱格式不正确。"
        case "weak_password": "密码至少 8 位，且不能过于简单。"
        case "too_many_attempts": "尝试次数过多，请稍后再试。"
        case "subscription_required": "需要订阅 iTalk 云端服务才能使用云端模型。"
        case "quota_exceeded": "本周或本订阅周期的用量已用完。"
        case "too_many_concurrent_requests": "同时进行的云端请求过多，请稍后再试。"
        case "model_not_in_plan": "当前订阅不包含这个模型。"
        case "feature_unavailable": "这项服务暂未开通。"
        case "invalid_identity_token": "Apple 登录验证失败。"
        case "invalid_token": "验证码不正确或已过期。"
        case "unsupported_image": "不支持这种图片格式。"
        case "image_too_large": "图片太大（上限 512 KB）。"
        case "provider_request_failed", "provider_error": "云端模型暂时无法响应，请稍后再试。"
        case "interrupted": "云端服务重启，这次回答被中断。"
        default: "云端服务返回错误（\(code)）。"
        }
    }
}

public struct CloudEvent: Sendable, Equatable {
    public var seq: Int
    public var type: String
    public var data: JSONValue
    public var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(type) }
}

/// Thin typed HTTP client for gateway v2 (see docs/gateway-v2-api.md). Holds no credentials of its own: the session token is read
/// through `token` on every call so sign-out takes effect immediately.
public final class CloudClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: @Sendable () -> String?
    private let session: URLSession
    private let streamSession: URLSession

    public init(baseURL: URL, token: @escaping @Sendable () -> String?, sessionOverride: URLSession? = nil) {
        self.baseURL = baseURL; self.token = token
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.timeoutIntervalForRequest = 30; c.waitsForConnectivity = false
        session = sessionOverride ?? URLSession(configuration: c)
        let s = URLSessionConfiguration.ephemeral; s.urlCache = nil; s.timeoutIntervalForRequest = 60; s.timeoutIntervalForResource = 3_600
        streamSession = sessionOverride ?? URLSession(configuration: s)
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], authorized: Bool = true) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var r = URLRequest(url: components.url!)
        r.httpMethod = method
        if authorized, let t = token(), !t.isEmpty { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func error(from data: Data, status: Int) -> CloudAPIError {
        let envelope = JSONValue.parse(String(decoding: data.prefix(8_192), as: UTF8.self))
        let err = envelope?["error"]
        let code = err?["code"]?.string ?? "gateway_\(status)"
        return CloudAPIError(code: code.utf8.count <= 64 ? code : "gateway_\(status)", status: status, detail: err?["detail"])
    }

    private func perform(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw CloudAPIError(code: "network", status: 0) }
            return (data, http)
        } catch let e as URLError where e.code != .cancelled {
            throw CloudAPIError(code: "network", status: 0)
        }
    }

    /// JSON in, JSON out. 2xx returns the decoded body (`.null` for 204); anything else throws `CloudAPIError`.
    @discardableResult
    public func json(_ method: String, _ path: String, body: JSONValue? = nil, query: [URLQueryItem] = [], idempotencyKey: String? = nil, authorized: Bool = true) async throws -> (status: Int, body: JSONValue) {
        var r = try request(method, path, query: query, authorized: authorized)
        if let body { r.httpBody = try AgentCoding.encoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { r.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let (data, http) = try await perform(r)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return (http.statusCode, data.isEmpty ? .null : (JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null))
    }

    /// Raw bytes in (avatar upload).
    public func upload(_ path: String, data: Data, contentType: String) async throws -> JSONValue {
        var r = try request("PUT", path)
        r.httpBody = data; r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (out, http) = try await perform(r)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: out, status: http.statusCode) }
        return JSONValue.parse(String(decoding: out, as: UTF8.self)) ?? .null
    }

    /// Raw bytes out (avatar download); nil when the resource does not exist.
    public func download(_ path: String) async throws -> (Data, String)? {
        let (data, http) = try await perform(try request("GET", path))
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    /// One Server-Sent-Events connection for a task, starting after `after`. Ends when the server closes it (after the terminal event) or
    /// throws `CloudAPIError(network)` when the connection drops; the caller reconnects with the last `seq` it applied.
    public func events(taskId: String, after: Int) -> AsyncThrowingStream<CloudEvent, Error> {
        let r = try? request("GET", "v2/tasks/\(taskId)/stream", query: [URLQueryItem(name: "after", value: String(after))])
        let session = streamSession
        return AsyncThrowingStream { continuation in
            guard var r else { continuation.finish(throwing: CloudAPIError(code: "invalid_request", status: 0)); return }
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: r)
                    guard let http = response as? HTTPURLResponse else { throw CloudAPIError(code: "network", status: 0) }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 8_192 { break } }
                        throw Self.error(from: body, status: http.statusCode)
                    }
                    // `bytes.lines` swallows empty lines, which are the event separators in SSE: split the bytes ourselves.
                    var id: Int?, type: String?, data = "", line = [UInt8]()
                    func handle(_ text: String) {
                        if text.isEmpty {
                            if let id, let type, let value = JSONValue.parse(data) { continuation.yield(CloudEvent(seq: id, type: type, data: value)) }
                            id = nil; type = nil; data = ""
                        } else if text.hasPrefix("id:") { id = Int(text.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
                        else if text.hasPrefix("event:") { type = text.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                        else if text.hasPrefix("data:") { data += text.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    }
                    for try await byte in bytes {
                        if byte == 0x0A {
                            try Task.checkCancellation()
                            var text = String(decoding: line, as: UTF8.self)
                            if text.hasSuffix("\r") { text.removeLast() }
                            line.removeAll(keepingCapacity: true)
                            handle(text)
                        } else {
                            line.append(byte)
                            if line.count > 1_000_000 { throw CloudAPIError(code: "event_too_large", status: 0) }
                        }
                    }
                    continuation.finish()
                } catch let e as CloudAPIError { continuation.finish(throwing: e) }
                catch is CancellationError { continuation.finish() }
                catch let e as URLError where e.code == .cancelled { continuation.finish() }
                catch { continuation.finish(throwing: CloudAPIError(code: "network", status: 0)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
