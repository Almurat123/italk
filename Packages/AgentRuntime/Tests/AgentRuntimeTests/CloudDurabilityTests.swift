import Foundation
import Testing
@testable import AgentRuntime

/// Runs against the real gateway v2 with a scripted model (`server/tools/fake-gateway.mjs`; see tools/cloud-e2e.sh):
///   ITALK_TEST_GATEWAY=http://127.0.0.1:<port> ITALK_TEST_TOKEN=<session token> swift test --filter CloudDurability
private let gateway = ProcessInfo.processInfo.environment["ITALK_TEST_GATEWAY"].flatMap(URL.init(string:))
private let sessionToken = ProcessInfo.processInfo.environment["ITALK_TEST_TOKEN"]

private func control(_ path: String) async throws -> JSONValue {
    let (data, _) = try await URLSession.shared.data(from: gateway!.appendingPathComponent(path))
    return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
}

private func collect(_ provider: CloudGatewayProvider, _ request: GenerationRequest) async throws -> (text: String, reasoning: String, calls: [ToolCall], usage: Usage?, finish: FinishReason?) {
    var text = "", reasoning = "", calls: [ToolCall] = [], usage: Usage?, finish: FinishReason?
    for try await e in provider.generate(request) {
        switch e {
        case .textDelta(let d): text += d
        case .reasoningDelta(let d): reasoning += d
        case .toolCall(let c): calls.append(c)
        case .usage(let u): usage = u
        case .completed(let f): finish = f
        }
    }
    return (text, reasoning, calls, usage, finish)
}

@Suite(.serialized, .enabled(if: gateway != nil && sessionToken != nil)) struct CloudDurability {
    private func provider(outage: TimeInterval = 20) -> CloudGatewayProvider {
        CloudGatewayProvider(client: CloudClient(baseURL: gateway!, token: { sessionToken }), modelName: "DeepSeek", modelId: "deepseek-flash", reasoningEffort: "low", outageLimit: outage)
    }
    private func request(_ text: String, id: String = UUID().uuidString.lowercased() + "/1") -> GenerationRequest {
        GenerationRequest(requestId: id, messages: [ModelMessage(role: .user, text: text)], tools: [], maxTokens: 200, reasoning: true)
    }

    @Test func streamsReasoningTextToolCallsAndUsage() async throws {
        let r = try await collect(provider(), request("请使用工具查天气"))
        #expect(r.text == "你好，世界")
        #expect(r.reasoning == "先想一想。")
        #expect(r.calls.map(\.name) == ["weather_forecast"] && r.calls.first?.arguments["place"]?.string == "杭州")
        #expect(r.finish == .toolCalls)
        #expect(r.usage?.promptTokens == 120 && r.usage?.completionTokens == 30)
    }

    @Test func connectionsDroppedMidStreamAreResumedWithoutRepeatsOrGaps() async throws {
        let p = provider()
        let before = try await control("__dev/stats")["providerCalls"]?.number ?? 0
        let reading = Task { try await collect(p, request("请写一段很长的回答")) }
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(600)); _ = try await control("__dev/drop") }   // cut every open connection, repeatedly
        let r = try await reading.value
        #expect(r.text == (1...12).map { "第\($0)段。" }.joined(), "text must be complete, in order, with nothing repeated")
        #expect(r.finish == .stop)
        #expect((try await control("__dev/stats"))["providerCalls"]?.number == before + 1, "the model was called once, not once per reconnect")
    }

    @Test func resubmittingTheSameStepNeverGeneratesTwice() async throws {
        let id = UUID().uuidString.lowercased() + "/3"
        let before = try await control("__dev/stats")["providerCalls"]?.number ?? 0
        let first = try await collect(provider(), request("你好", id: id))
        let again = try await collect(provider(), request("你好", id: id))          // e.g. the app was killed and the run resumed
        #expect(first.text == again.text && !first.text.isEmpty)
        #expect((try await control("__dev/stats"))["providerCalls"]?.number == before + 1)
    }

    @Test func cancellingTheReaderCancelsTheTask() async throws {
        let p = provider()
        let reading = Task { try await collect(p, request("请写一段很长的回答")) }
        try await Task.sleep(for: .milliseconds(700))
        reading.cancel()
        _ = try? await reading.value
        try await Task.sleep(for: .milliseconds(800))
        let client = CloudClient(baseURL: gateway!, token: { sessionToken })
        let list = try await client.json("GET", "v2/tasks", query: [URLQueryItem(name: "limit", value: "1")]).body["tasks"]?.array ?? []
        #expect(list.first?["state"]?.string == "cancelled")
    }

    @Test func gatewayErrorsBecomeProviderErrorsWithStableCodes() async throws {
        let bad = CloudGatewayProvider(client: CloudClient(baseURL: gateway!, token: { "not-a-session-token-at-all" }), modelName: "x", modelId: "deepseek-flash")
        do { _ = try await collect(bad, request("hi")); Issue.record("expected an error") }
        catch let e as ProviderError { #expect(e == .failed("unauthorized")) }
    }
}
