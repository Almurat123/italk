import Foundation

// The paid iTalk cloud model as an ordinary `ModelProvider`: the same runner, skills, tools, permissions and journal as local models.
//
// One model step = one durable gateway task (docs/gateway-v2-api.md). The task runs on the gateway whether or not this phone stays
// connected; this provider is only a *reader* of its ordered event log. Dropped connections, network switches and phone calls are
// handled by reconnecting with the last applied sequence number, never by resubmitting. The idempotency key is the request id, which
// the runner derives from (run, step), so even a resubmission after the app was killed returns the existing task and replays its
// result instead of billing a second time. Tools always execute on the iPhone.
public final class CloudGatewayProvider: ModelProvider, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    private let client: CloudClient
    private let modelId: String
    private let reasoningEffort: String
    /// How long a dropped connection may stay down before the step is parked as "waiting for network".
    private let outageLimit: TimeInterval

    public init(client: CloudClient, modelName: String, modelId: String, reasoningEffort: String = "none", contextWindow: Int = 128_000, vision: Bool = false,
                outageLimit: TimeInterval = 45) {
        self.client = client; self.modelId = modelId; self.reasoningEffort = reasoningEffort; self.outageLimit = outageLimit
        descriptor = ModelDescriptor(id: "italk-cloud/" + modelId, kind: .cloudGateway, displayName: modelName, capabilities: ProviderCapabilities(
            contextWindow: contextWindow, toolCalling: .native, structuredOutput: false, maxAutonomy: .fullAgent, worksOffline: false,
            sendsContentOffDevice: true, visionInput: vision))
    }

    public func prepare(progress: @Sendable (PreparationState) -> Void) async throws { progress(.ready) }
    public func unload() async {}

    /// ToolSpec → JSON Schema (strict: unknown properties rejected, like the on-device validator).
    public static func schema(_ spec: ToolSpec) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (k, p) in spec.parameters {
            var o: [String: JSONValue] = ["description": .string(p.description)]
            switch p.kind {
            case .array: o["type"] = .string("array"); o["items"] = .object([:])
            case .object: o["type"] = .string("object")
            default: o["type"] = .string(p.kind.rawValue)
            }
            if let e = p.enumValues { o["enum"] = .array(e.map(JSONValue.string)) }
            if let m = p.maxLength { o["maxLength"] = .number(Double(m)) }
            if let m = p.minimum { o["minimum"] = .number(m) }
            if let m = p.maximum { o["maximum"] = .number(m) }
            props[k] = .object(o)
        }
        return .object(["type": .string("object"), "properties": .object(props), "additionalProperties": .bool(false),
                        "required": .array(spec.parameters.filter(\.value.required).keys.sorted().map(JSONValue.string))])
    }

    static func taskBody(_ r: GenerationRequest, modelId: String, reasoningEffort: String) -> JSONValue {
        let messages: [JSONValue] = r.messages.map { m in
            var o: [String: JSONValue] = ["role": .string(m.role.rawValue), "text": .string(m.text)]
            if !m.toolCalls.isEmpty { o["toolCalls"] = .array(m.toolCalls.map { .object(["id": .string($0.id), "name": .string($0.name), "arguments": .string($0.arguments.compactString)]) }) }
            if let id = m.toolCallId { o["toolCallId"] = .string(id) }
            // Reasoning of earlier tool-call turns is replayed when the model produced it; history from another model simply has none.
            if m.role == .assistant, !m.toolCalls.isEmpty, let reasoning = m.reasoningContent { o["reasoningContent"] = .string(reasoning) }
            return .object(o)
        }
        // Only the newest user turn's images are sent (the person approved them for this turn).
        let images: [JSONValue] = (r.messages.last { $0.role == .user }?.images ?? []).prefix(3).compactMap { img in
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: img.filePath)), d.count <= 900_000 else { return nil }
            return .object(["mimeType": .string("image/jpeg"), "data": .string(d.base64EncodedString())])
        }
        var o: [String: JSONValue] = ["model": .string(modelId), "messages": .array(messages),
            "tools": .array(r.tools.map { .object(["name": .string($0.name), "description": .string($0.description), "parameters": schema($0)]) }),
            "maxTokens": .number(Double(min(max(r.maxTokens, 1), 4000)))]
        if !images.isEmpty { o["images"] = .array(images) }
        if r.reasoning, ["low", "high", "max"].contains(reasoningEffort) { o["reasoningEffort"] = .string(reasoningEffort) }
        // requestId = "<runId>/<step>": groups the steps of one run on the gateway.
        let parts = r.requestId.split(separator: "/")
        if parts.count == 2, let step = Int(parts[1]) { o["runId"] = .string(String(parts[0])); o["step"] = .number(Double(step)) }
        return .object(o)
    }

    private static func providerError(_ e: CloudAPIError) -> ProviderError {
        e.isNetwork ? .network : .failed(e.code.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) ? e.code : "gateway_\(e.status)")
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let client = client, providerId = descriptor.id, outageLimit = outageLimit
        let body = Self.taskBody(request, modelId: modelId, reasoningEffort: reasoningEffort)
        let key = request.requestId.count >= 8 ? request.requestId : request.requestId + "-" + UUID().uuidString
        return AsyncThrowingStream { continuation in
            let box = TaskBox()
            let task = Task {
                var outageStart: Date?
                func backoff(_ n: Int) async throws {
                    if outageStart == nil { outageStart = Date() }
                    if Date().timeIntervalSince(outageStart!) > outageLimit { box.networkLoss = true; throw ProviderError.network }
                    try await Task.sleep(for: .milliseconds(min(8_000, 400 * (1 << min(n, 5)))))
                }
                do {
                    // 1. Submit (idempotent: a retry after a lost response returns the same task).
                    var attempt = 0
                    while box.id == nil {
                        do {
                            let (_, result) = try await client.json("POST", "v2/tasks", body: body, idempotencyKey: key)
                            guard let id = result["task"]?["id"]?.string else { throw ProviderError.failed("gateway_bad_response") }
                            box.id = id
                        } catch let e as CloudAPIError where e.isNetwork { attempt += 1; try await backoff(attempt) }
                        catch let e as CloudAPIError { throw Self.providerError(e) }
                    }
                    outageStart = nil
                    // 2. Read the event log from the cursor; reconnect from the last applied seq whenever the connection drops.
                    var cursor = 0, usage: Usage?, finish = FinishReason.stop, terminal: CloudEvent?
                    let started = Date(); var firstToken: Double?
                    attempt = 0
                    while terminal == nil {
                        try Task.checkCancellation()
                        do {
                            for try await event in client.events(taskId: box.id!, after: cursor) {
                                try Task.checkCancellation()
                                guard event.seq > cursor else { continue }
                                cursor = event.seq; outageStart = nil; attempt = 0
                                switch event.type {
                                case "delta": if let t = event.data["text"]?.string { if firstToken == nil { firstToken = Date().timeIntervalSince(started) }; continuation.yield(.textDelta(t)) }
                                case "reasoning": if let t = event.data["text"]?.string { continuation.yield(.reasoningDelta(t)) }
                                case "tool_call":
                                    guard let id = event.data["id"]?.string, let name = event.data["name"]?.string else { continue }
                                    continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: event.data["arguments"]?.string.flatMap(JSONValue.parse) ?? .object([:]))))
                                case "usage":
                                    usage = Usage(promptTokens: Int(event.data["inputTokens"]?.number ?? 0), completionTokens: Int(event.data["outputTokens"]?.number ?? 0),
                                                  firstTokenLatency: firstToken, providerId: providerId)
                                case "completed": finish = FinishReason(rawValue: event.data["finishReason"]?.string ?? "stop") ?? .stop; terminal = event
                                case "failed", "cancelled": terminal = event
                                default: break
                                }
                                if terminal != nil { break }
                            }
                            if terminal == nil { attempt += 1; try await backoff(attempt) }          // closed without a terminal event: reconnect
                        } catch let e as CloudAPIError where e.isNetwork { attempt += 1; try await backoff(attempt) }
                        catch let e as CloudAPIError { throw Self.providerError(e) }
                    }
                    switch terminal!.type {
                    case "completed":
                        if let usage { continuation.yield(.usage(usage)) }
                        box.finished = true
                        continuation.yield(.completed(finish)); continuation.finish()
                    case "cancelled": box.finished = true; throw CancellationError()
                    default: box.finished = true; throw ProviderError.failed(terminal!.data["code"]?.string ?? "provider_error")
                    }
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // The reader went away on purpose (stop, barge-in, model switch): tell the gateway so it stops producing and billing.
                // A reader that merely lost its network does NOT cancel; the task keeps running and the next reader picks it up.
                if let id = box.id, !box.finished, !box.networkLoss { Task { _ = try? await client.json("POST", "v2/tasks/\(id)/cancel") } }
            }
        }
    }

    /// Mutable state shared between the reading task and its termination handler.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _id: String?, _finished = false, _networkLoss = false
        var id: String? { get { lock.withLock { _id } } set { lock.withLock { _id = newValue } } }
        var finished: Bool { get { lock.withLock { _finished } } set { lock.withLock { _finished = newValue } } }
        var networkLoss: Bool { get { lock.withLock { _networkLoss } } set { lock.withLock { _networkLoss = newValue } } }
    }
}
