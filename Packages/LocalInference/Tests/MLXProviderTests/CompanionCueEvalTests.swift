import Foundation
import Testing
import AgentRuntime
import AppleSkills
import MLXProvider

// How reliably does a real model declare the tone of its answer (ToneProtocol), and does anything leak into visible text?
//
//   TEST_RUNNER_ITALK_CUE_EVAL=1 TEST_RUNNER_ITALK_CUE_PROVIDER=mlx TEST_RUNNER_ITALK_MODEL_DIR=<model folder> \
//   TEST_RUNNER_ITALK_CUE_PROMPTS=tools/companion-eval/prompts.json TEST_RUNNER_ITALK_CUE_SAMPLES=2 TEST_RUNNER_ITALK_CUE_OUT=<out.json> \
//   xcodebuild test -scheme LocalInference -destination 'platform=macOS' -only-testing:MLXProviderTests/companionCuesWithRealModel()
//
//   Provider `deepseek`: an OpenAI-compatible chat-completions endpoint (MODEL_BASE_URL, MODEL_API_KEY, MODEL_ID of server/.env, handed in by
//   run.sh through the test environment). The key is used at run time and never printed or written anywhere.
//
// Every prompt goes through the production runner, system prompt and tone filter. The raw model text (before the filter) is kept so
// leaks and malformed tags can be counted; the summary is computed by tools/companion-eval/summarize.mjs.

#if targetEnvironment(simulator)
private let cueEvalAvailable = false
#else
private let cueEvalAvailable = true
#endif

/// Keeps the raw text of every generation, before the runner strips tone tags.
final class CueRecordingProvider: ModelProvider, @unchecked Sendable {
    let inner: any ModelProvider
    private let lock = NSLock()
    private var texts: [String] = []
    private var lastUsage: Usage?
    init(_ inner: any ModelProvider) { self.inner = inner }
    var descriptor: ModelDescriptor { inner.descriptor }
    func prepare(progress: @Sendable (PreparationState) -> Void) async throws { try await inner.prepare(progress: progress) }
    func unload() async { await inner.unload() }
    func reset() { lock.withLock { texts = []; lastUsage = nil } }
    var generations: [String] { lock.withLock { texts } }
    var usage: Usage? { lock.withLock { lastUsage } }
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let source = inner.generate(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                do {
                    for try await event in source {
                        if case .textDelta(let d) = event { text += d }
                        if case .usage(let u) = event { self.lock.withLock { self.lastUsage = u } }
                        continuation.yield(event)
                    }
                    self.lock.withLock { self.texts.append(text) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A chat-completions endpoint as a provider, for measuring a managed cloud model through the same runner.
struct ChatCompletionsEvalProvider: ModelProvider {
    let baseURL: URL, key: String, model: String
    var descriptor: ModelDescriptor { .scripted(id: "eval-\(model)", kind: .cloudGateway, offline: false) }
    func prepare(progress: @Sendable (PreparationState) -> Void) async throws { progress(.ready) }
    func unload() async {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var url = baseURL
                    if !url.path.hasSuffix("/chat/completions") { url = url.appendingPathComponent("chat/completions") }
                    var http = URLRequest(url: url)
                    http.httpMethod = "POST"
                    http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    http.timeoutInterval = 120
                    let messages = request.messages.map { ["role": $0.role == .tool ? "user" : $0.role.rawValue, "content": $0.text] }
                    let body: [String: Any] = ["model": model, "messages": messages, "stream": true, "max_tokens": max(request.maxTokens, 256),
                                               "temperature": request.temperature, "stream_options": ["include_usage": true]]
                    http.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: http)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.failed("http \((response as? HTTPURLResponse)?.statusCode ?? -1)") }
                    var finish: FinishReason = .stop
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let usage = object["usage"] as? [String: Any], let prompt = usage["prompt_tokens"] as? Int, let completion = usage["completion_tokens"] as? Int {
                            continuation.yield(.usage(Usage(promptTokens: prompt, completionTokens: completion, providerId: "eval")))
                        }
                        guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
                        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty { continuation.yield(.textDelta(content)) }
                        if let reason = choice["finish_reason"] as? String, reason == "length" { finish = .length }
                    }
                    continuation.yield(.completed(finish))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Collects the transient tone-segment events of one run.
final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<AgentEvent>) {
        task = Task { [weak self] in
            for await e in stream {
                if e.type == .companionSegment, case .segment(let s) = e.payload {
                    self?.lock.withLock { self?.items.append(["label": s.label, "offset": s.offset, "intensity": s.intensity as Any]) }
                }
            }
        }
    }
    func finish() -> [[String: Any]] { task?.cancel(); return lock.withLock { items } }
}

private func dotenv(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        out[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
    return out
}

@Test(.enabled(if: cueEvalAvailable && ProcessInfo.processInfo.environment["ITALK_CUE_EVAL"] == "1"))
func companionCuesWithRealModel() async throws {
    let env = ProcessInfo.processInfo.environment
    let samples = Int(env["ITALK_CUE_SAMPLES"] ?? "2") ?? 2
    let only = env["ITALK_CUE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let prompts = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env["ITALK_CUE_PROMPTS"]!))) as! [[String: Any]]

    let label: String
    let base: any ModelProvider
    if env["ITALK_CUE_PROVIDER"] == "deepseek" {
        // Values come from the environment (tools/companion-eval/run.sh) or, for a quick run outside ~/Documents, from a dotenv file.
        let cfg = env["ITALK_CUE_KEY"] != nil ? ["MODEL_BASE_URL": env["ITALK_CUE_BASE_URL"] ?? "", "MODEL_API_KEY": env["ITALK_CUE_KEY"] ?? "", "MODEL_ID": env["ITALK_CUE_MODEL"] ?? ""]
                                              : dotenv(env["ITALK_CUE_ENV"] ?? "")
        guard let url = cfg["MODEL_BASE_URL"].flatMap(URL.init(string:)), let key = cfg["MODEL_API_KEY"], !key.isEmpty else { throw ProviderError.failed("MODEL_BASE_URL / MODEL_API_KEY missing") }
        let model = cfg["MODEL_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "deepseek-chat"
        base = ChatCompletionsEvalProvider(baseURL: url, key: key, model: model)
        label = "managed-cloud:\(model)"
    } else {
        let dir = URL(fileURLWithPath: env["ITALK_MODEL_DIR"]!)
        let artifact = ModelArtifact(id: dir.lastPathComponent, displayName: dir.lastPathComponent, version: "bench", license: "apache-2.0", baseModelLicense: "apache-2.0",
                                     files: [], residentBytes: 0, kvBytesPerToken: 0, contextTokens: 4096, maxAutonomy: .fullAgent, autonomySource: "bench")
        base = MLXModelProvider(artifact: artifact, directory: dir)
        label = "local:\(dir.lastPathComponent)"
    }
    let provider = CueRecordingProvider(base)
    try await provider.prepare { _ in }

    var rows: [[String: Any]] = []
    for item in prompts {
        let id = item["id"] as! String
        if let only, !only.contains(id) && !only.contains(item["category"] as! String) { continue }
        for sample in 0..<samples {
            provider.reset()
            var reg = ToolRegistry(), cat = SkillCatalog([])
            AppleSkills.install(into: &reg, catalog: &cat, context: AppleSkillContext(presenter: E2EUI(), filesRoot: FileManager.default.temporaryDirectory))
            var all = SkillCatalog([SkillCatalog.standard.skill("core")!]); all.add(WebSkill.skill); all.add(cat.skills)
            var tools = ToolRegistry([DateTimeTool(), CalculatorTool()])
            for n in reg.names { if let t = reg.tool(named: n) { tools.register(t) } }
            var config = RunnerConfig()
            config.semanticCues = env["ITALK_CUE_ON"] != "0"
            if let wording = env["ITALK_CUE_INSTRUCTION"], !wording.isEmpty { config.toneInstruction = wording }     // A/B of instruction wordings
            if let mode = env["ITALK_SELECTION"].flatMap(SkillSelectionMode.init(rawValue:)) { config.skillSelectionOverride = mode }
            let runner = AgentRunner(provider: provider, tools: tools, skills: all, store: InMemoryRunStore(), permissions: StaticPermissionAuthority(), config: config)
            let collector = SegmentCollector(await runner.bus.subscribe(buffer: 8192))
            let t0 = ContinuousClock.now
            let run = try await runner.start(conversationId: UUID(), text: item["prompt"] as! String, source: env["ITALK_CUE_VOICE"] == "1" ? "voice" : "text")
            var declined = 0
            while true {
                await runner.waitUntilIdle(run)
                let s = await runner.snapshot(run)!
                if s.state == .awaitingApproval, declined < 3, let p = s.pending, let c = s.components[p.componentId]?.component {
                    declined += 1                                                    // no tool may act in this measurement
                    try await runner.submit(UIActionResponse(runId: run, componentId: c.id, componentRevision: c.revision, actionId: "decline", idempotencyKey: "d\(declined)", authorization: .none))
                    continue
                }
                break
            }
            let snapshot = await runner.snapshot(run)!
            let d = (ContinuousClock.now - t0).components
            try await Task.sleep(for: .milliseconds(100))                         // the last events are still in flight
            let segments = collector.finish()
            rows.append(["id": id, "category": item["category"] as! String, "sample": sample, "prompt": item["prompt"] as! String,
                         "accept": item["accept"] as Any, "neutralOK": item["neutralOK"] as Any,
                         "state": snapshot.state.rawValue, "raw": provider.generations.last ?? "", "generations": provider.generations.count, "clean": snapshot.finalText ?? "",
                         "segments": segments, "toolCalls": snapshot.toolCalls, "seconds": Double(d.seconds) + Double(d.attoseconds) / 1e18,
                         "completionTokens": provider.usage?.completionTokens ?? 0, "promptTokens": provider.usage?.promptTokens ?? 0])
            print("CUE \(id)#\(sample) tags=\(segments.map { $0["label"] as! String }) state=\(snapshot.state.rawValue)")
        }
    }
    if let out = env["ITALK_CUE_OUT"] {
        let payload: [String: Any] = ["model": label, "cuesOn": config_on(env), "samples": samples, "date": ISO8601DateFormatter().string(from: .now), "rows": rows]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    }
    await provider.unload()
}

private func config_on(_ env: [String: String]) -> Bool { env["ITALK_CUE_ON"] != "0" }
