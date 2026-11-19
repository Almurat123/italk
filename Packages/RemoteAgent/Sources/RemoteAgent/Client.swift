import Foundation
import CryptoKit
import AgentRuntime

public struct PairingError: Error, Sendable, Equatable { public let failure: PairingFailure }

public enum RemotePairing {
    public enum Stage: Sendable, Equatable {
        case connecting
        /// The request reached the computer; the person has to allow this phone there. `phoneFingerprint` is what the computer shows.
        case awaitingApprovalOnComputer(phoneFingerprint: String)
    }

    /// Pairs with the computer that displayed `link`. Succeeds only if the computer proves it holds the key from the QR code.
    public static func pair(link: RemotePairingLink, identity: PhoneIdentity, phoneName: String, progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> AgentRecord {
        let transport = PinnedSession(pin: link.certificatePin)
        defer { transport.invalidate() }
        progress(.connecting)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) }).base64URLString
        let phoneKey = identity.publicKey.base64URLString
        let mac = HMAC<SHA256>.authenticationCode(for: Data("pair|\(link.pairingId)|\(phoneKey)|\(nonce)".utf8), using: SymmetricKey(data: Data(link.secret.utf8)))
        let body = try JSONSerialization.data(withJSONObject: ["pairingId": link.pairingId, "phonePublicKey": phoneKey, "phoneName": phoneName, "nonce": nonce, "proof": Data(mac).base64URLString])
        var sawMismatch = false
        for endpoint in link.endpoints {
            // CONTEXT MEMORY
            // Updated: 2026-11-02
            // Status: inferred
            // Why: A LAN address may be unreachable when the phone is on a private remote network.
            // Debug Goal: Move past dead addresses without consuming the one-time pairing secret.
            // Search Tags: pairing unreachable endpoint timeout tailscale
            // Invariants:
            // - Probe uses the same certificate pin and never submits the pairing proof.
            // - Only one reachable endpoint receives the one-time pairing request.
            // Failure Modes:
            // - An unreachable first address stalls pairing for the full approval timeout.
            guard let helloURL = URL(string: "https://\(endpoint)/v1/hello") else { continue }
            var hello = URLRequest(url: helloURL); hello.timeoutInterval = 3
            do {
                let (_, response) = try await transport.session.data(for: hello)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
            } catch let error as URLError {
                if transport.takeMismatch() { sawMismatch = true; continue }
                if error.code == .cancelled { throw PairingError(failure: .cancelled) }
                continue
            } catch { continue }
            guard let url = URL(string: "https://\(endpoint)/v1/pair") else { continue }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 150
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let waiting = Task { try? await Task.sleep(for: .seconds(1.5)); if !Task.isCancelled { progress(.awaitingApprovalOnComputer(phoneFingerprint: identity.fingerprint)) } }
            do {
                let (data, response) = try await transport.session.data(for: request)
                waiting.cancel()
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode != 200 {
                    let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code ?? "unknown"
                    switch (http.statusCode, code) {
                    case (410, _): throw PairingError(failure: .expired)
                    case (403, "rejected_by_computer"): throw PairingError(failure: .rejectedByComputer)
                    case (403, _), (400, _): throw PairingError(failure: .invalidCode)
                    case (429, _): throw PairingError(failure: .unreachable)
                    default: throw PairingError(failure: .protocolMismatch)
                    }
                }
                struct Reply: Decodable { var phoneId: String; var agentId: String; var signature: String }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let signature = Data(base64URL: reply.signature),
                      reply.agentId == link.agentId,
                      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: link.agentKey),
                      key.isValidSignature(signature, for: Data("italk-pairing-v1|\(link.pairingId)|\(phoneKey)|\(link.agentId)|\(nonce)".utf8)) else { throw PairingError(failure: .identityMismatch) }
                return AgentRecord(id: link.agentId, name: link.name, publicKey: link.agentKey, certificatePin: link.certificatePin, endpoints: link.endpoints, phoneId: reply.phoneId, pairedAt: Date())
            } catch let error as PairingError { waiting.cancel(); throw error }
            catch let error as URLError {
                waiting.cancel()
                if transport.takeMismatch() { sawMismatch = true; continue }
                if error.code == .cancelled { throw PairingError(failure: .cancelled) }
                continue
            } catch { waiting.cancel(); continue }
        }
        throw PairingError(failure: sawMismatch ? .identityMismatch : .unreachable)
    }
}

struct ErrorEnvelope: Decodable { struct Body: Decodable { var code: String }; var error: Body }

public enum RemoteConnectionStatus: Sendable, Equatable { case connected, reconnecting(attempt: Int) }

/// Talks to one paired computer. Every request after pairing is signed with the phone's key; the certificate is pinned.
public actor RemoteAgentClient {
    public nonisolated let record: AgentRecord
    private let identity: PhoneIdentity
    private let transport: PinnedSession
    private var preferred = 0
    private var clockOffsetMs: Double = 0
    private var clockSyncedAt: Date?

    public init(record: AgentRecord, identity: PhoneIdentity) {
        self.record = record; self.identity = identity; self.transport = PinnedSession(pin: record.certificatePin)
    }

    deinit { transport.invalidate() }
    public nonisolated func invalidate() { transport.invalidate() }

    // MARK: Requests

    public struct Hello: Decodable, Sendable { public struct Agent: Decodable, Sendable { public var id: String; public var name: String; public var version: String }; public var agent: Agent; public var time: Double }

    /// Unsigned reachability check; also learns the computer's clock so signatures are accepted even if the phone clock is a little off.
    public func hello() async throws -> Hello {
        let (data, http) = try await perform { base in try self.plainRequest("GET", "/v1/hello", base: base, timeout: 6) }
        guard http.statusCode == 200, let hello = try? JSONDecoder().decode(Hello.self, from: data) else { throw try mapError(http, data) }
        guard hello.agent.id == record.id else { throw RemoteError.identityMismatch }
        clockOffsetMs = hello.time - Date().timeIntervalSince1970 * 1000; clockSyncedAt = Date()
        return hello
    }

    public func status() async throws -> AgentStatus { try await get("/v1/status") }
    public func tasks(limit: Int = 30) async throws -> [RemoteTaskSnapshot] {
        struct R: Decodable { var tasks: [RemoteTaskSnapshot] }
        return (try await get("/v1/tasks?limit=\(limit)") as R).tasks
    }
    public func task(_ id: String) async throws -> RemoteTaskSnapshot {
        struct R: Decodable { var task: RemoteTaskSnapshot }
        return (try await get("/v1/tasks/\(id)") as R).task
    }

    /// Idempotent: resubmitting with the same key returns the same task (nothing runs twice), so a retry after a timeout is always safe.
    public func createTask(_ task: NewRemoteTask, idempotencyKey: String) async throws -> RemoteTaskSnapshot {
        struct R: Decodable { var task: RemoteTaskSnapshot }
        let body = try JSONEncoder().encode(task)
        return (try await signed("POST", "/v1/tasks", body: body, idempotencyKey: idempotencyKey) as R).task
    }
    public func cancel(taskId: String) async throws -> RemoteTaskSnapshot {
        struct R: Decodable { var task: RemoteTaskSnapshot }
        return (try await signed("POST", "/v1/tasks/\(taskId)/cancel", body: Data("{}".utf8)) as R).task
    }
    public func deleteTask(_ id: String) async throws { _ = try await raw("DELETE", "/v1/tasks/\(id)", body: nil, idempotencyKey: nil) }

    public func approvals() async throws -> [RemoteApproval] {
        struct R: Decodable { var approvals: [RemoteApproval] }
        return (try await get("/v1/approvals") as R).approvals
    }
    /// `scope`: "once" or "task" (the rest of this task). The computer clamps it to what the action's risk allows.
    public func resolveApproval(id: String, approve: Bool, scope: String = "once") async throws {
        struct R: Decodable { var approval: RemoteApproval? }
        let body = try JSONSerialization.data(withJSONObject: ["decision": approve ? "approve" : "decline", "scope": scope])
        let _: R = try await signed("POST", "/v1/approvals/\(id)", body: body)
    }
    // MARK: Model access and discovery

    /// Hands this computer a credential for iTalk's gateway (a scoped session of the person's own account) and returns the computer's own check of it.
    /// The credential travels only over the pinned, signed channel and is never sent back.
    public func provisionCloud(gateway: String, token: String, expiresAt: Double?, accountHint: String?, sessionName: String?) async throws -> CloudState {
        var body: [String: Any] = ["gateway": gateway, "token": token]
        if let expiresAt { body["expiresAt"] = expiresAt }
        if let accountHint { body["accountHint"] = accountHint }
        if let sessionName { body["sessionName"] = sessionName }
        return try await signed("PUT", "/v1/cloud", body: JSONSerialization.data(withJSONObject: body))
    }
    public func cloud() async throws -> CloudState { try await get("/v1/cloud") }
    /// A fresh round trip from the computer to the gateway: credential accepted, subscription active, which models may run.
    public func verifyCloud() async throws -> CloudState { try await signed("POST", "/v1/cloud/verify", body: Data("{}".utf8)) }
    public func clearCloud() async throws { _ = try await raw("DELETE", "/v1/cloud", body: nil, idempotencyKey: nil) }
    public func capabilities(cwd: String? = nil) async throws -> AgentCapabilities {
        struct R: Decodable { var capabilities: AgentCapabilities }
        let q = cwd.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) }.map { "?cwd=\($0)" } ?? ""
        return (try await get("/v1/capabilities\(q)") as R).capabilities
    }
    /// Answers a question the agent asked (`question_requested` in the event log).
    public func answer(questionId: String, text: String) async throws {
        struct R: Decodable { var ok: Bool? }
        let _: R = try await signed("POST", "/v1/questions/\(questionId)", body: JSONSerialization.data(withJSONObject: ["answer": text]))
    }

    public func folders(path: String) async throws -> RemoteFolders {
        let q = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        return try await get("/v1/folders?path=\(q)")
    }
    public func pollEvents(taskId: String, after: Int) async throws -> (events: [RemoteEvent], task: RemoteTaskSnapshot) {
        struct Raw: Decodable { struct E: Decodable { var seq: Int; var type: String; var data: JSONValue }; var events: [E]; var task: RemoteTaskSnapshot }
        let r: Raw = try await get("/v1/tasks/\(taskId)/events?after=\(after)&limit=1000")
        return (r.events.map { RemoteEvent(seq: $0.seq, type: $0.type, data: $0.data) }, r.task)
    }
    /// Removes this phone from the computer. The pairing record on the phone should be deleted by the caller afterwards.
    public func unpair() async throws { _ = try await raw("DELETE", "/v1/device", body: nil, idempotencyKey: nil) }

    // MARK: Event stream (resumes by itself)

    /// Server-Sent Events from `after`. Reconnects with the last sequence it applied, so nothing is repeated or skipped; finishes after the terminal
    /// event, and throws only for errors that retrying cannot fix (revoked, unknown task, wrong certificate).
    public nonisolated func events(taskId: String, after: Int = 0, onConnection: (@Sendable (RemoteConnectionStatus) -> Void)? = nil) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task { await self.pump(taskId: taskId, after: after, continuation: continuation, onConnection: onConnection) }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    private func pump(taskId: String, after: Int, continuation: AsyncThrowingStream<RemoteEvent, Error>.Continuation, onConnection: (@Sendable (RemoteConnectionStatus) -> Void)?) async {
        var last = after, attempt = 0
        while !Task.isCancelled {
            do {
                let bytes = try await openStream("/v1/tasks/\(taskId)/stream?after=\(last)")
                attempt = 0; onConnection?(.connected)
                var parser = SSEParser()
                for try await byte in bytes {
                    guard let e = parser.feed(byte), let seq = e.id, seq > last, let data = e.data.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
                    last = seq
                    let event = RemoteEvent(seq: seq, type: e.name, data: json)
                    continuation.yield(event)
                    if event.isTerminal { continuation.finish(); return }
                }
                // The connection ended without a terminal event: ask the computer where the task stands.
                let polled = try await pollEvents(taskId: taskId, after: last)
                for event in polled.events where event.seq > last { last = event.seq; continuation.yield(event); if event.isTerminal { continuation.finish(); return } }
                if polled.task.isFinished && last >= polled.task.lastSeq { continuation.finish(); return }
            } catch is CancellationError { continuation.finish(); return }
            catch let error as RemoteError {
                switch error {
                case .unreachable, .clockSkew: break
                default: continuation.finish(throwing: error); return
                }
            } catch let error as URLError where error.code == .cancelled { continuation.finish(); return }
            catch { /* transient transport error */ }
            if Task.isCancelled { break }
            attempt += 1; onConnection?(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: .seconds(min(15, 0.5 * pow(2, Double(min(attempt - 1, 5))))))
        }
        continuation.finish()
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ target: String) async throws -> T { try await signed("GET", target, body: nil) }

    private func signed<T: Decodable>(_ method: String, _ target: String, body: Data?, idempotencyKey: String? = nil) async throws -> T {
        let data = try await raw(method, target, body: body, idempotencyKey: idempotencyKey)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw RemoteError.malformedResponse }
    }

    private func raw(_ method: String, _ target: String, body: Data?, idempotencyKey: String?) async throws -> Data {
        if clockSyncedAt == nil { _ = try? await hello() }
        var (data, http) = try await perform { base in try self.signedRequest(method, target, body: body, base: base, idempotencyKey: idempotencyKey) }
        if http.statusCode == 401, (try? mapError(http, data)) as RemoteError? == .clockSkew || errorCode(data) == "stale_request" {
            _ = try await hello()
            (data, http) = try await perform { base in try self.signedRequest(method, target, body: body, base: base, idempotencyKey: idempotencyKey) }
        }
        guard (200..<300).contains(http.statusCode) else { throw try mapError(http, data) }
        return data
    }

    private func openStream(_ target: String) async throws -> URLSession.AsyncBytes {
        var sawMismatch = false
        let count = record.endpoints.count
        for offset in 0..<count {
            let index = (preferred + offset) % count
            let request = try signedRequest("GET", target, body: nil, base: record.endpoints[index], idempotencyKey: nil, timeout: 20)
            do {
                let (bytes, response) = try await transport.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw RemoteError.malformedResponse }
                if http.statusCode != 200 {
                    var body = Data(); for try await b in bytes { body.append(b); if body.count > 4096 { break } }
                    throw try mapError(http, body)
                }
                preferred = index
                return bytes
            } catch let error as URLError {
                if transport.takeMismatch() { sawMismatch = true; continue }
                if error.code == .cancelled { throw CancellationError() }
                continue
            }
        }
        throw sawMismatch ? RemoteError.identityMismatch : RemoteError.unreachable
    }

    private func perform(_ build: (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var sawMismatch = false
        let count = record.endpoints.count
        for offset in 0..<count {
            let index = (preferred + offset) % count
            do {
                let (data, response) = try await transport.session.data(for: try build(record.endpoints[index]))
                guard let http = response as? HTTPURLResponse else { throw RemoteError.malformedResponse }
                preferred = index
                return (data, http)
            } catch let error as URLError {
                if transport.takeMismatch() { sawMismatch = true; continue }
                if error.code == .cancelled { throw CancellationError() }
                continue
            }
        }
        throw sawMismatch ? RemoteError.identityMismatch : RemoteError.unreachable
    }

    private nonisolated func plainRequest(_ method: String, _ target: String, base: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "https://\(base)\(target)") else { throw RemoteError.malformedResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        return request
    }

    private func signedRequest(_ method: String, _ target: String, body: Data?, base: String, idempotencyKey: String?, timeout: TimeInterval = 25) throws -> URLRequest {
        var request = try plainRequest(method, target, base: base, timeout: timeout)
        let bytes = body ?? Data()
        let time = Int((Date().timeIntervalSince1970 * 1000 + clockOffsetMs).rounded())
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) }).base64URLString
        let signature = try identity.sign(Data("\(method)\n\(target)\n\(time)\n\(nonce)\n\(bytes.sha256Hex)".utf8)).base64URLString
        request.setValue(record.phoneId, forHTTPHeaderField: "x-italk-key"); request.setValue(String(time), forHTTPHeaderField: "x-italk-time")
        request.setValue(nonce, forHTTPHeaderField: "x-italk-nonce"); request.setValue(signature, forHTTPHeaderField: "x-italk-sig")
        if body != nil { request.httpBody = bytes; request.setValue("application/json", forHTTPHeaderField: "content-type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "idempotency-key") }
        return request
    }

    private nonisolated func errorCode(_ data: Data) -> String? { (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code }

    private nonisolated func mapError(_ http: HTTPURLResponse, _ data: Data) throws -> RemoteError {
        let code = errorCode(data) ?? "http_\(http.statusCode)"
        switch (http.statusCode, code) {
        case (_, "revoked"): return .revoked
        case (_, "stale_request"): return .clockSkew
        case (401, "unknown_device"): return .revoked
        default: return .http(status: http.statusCode, code: code)
        }
    }
}
