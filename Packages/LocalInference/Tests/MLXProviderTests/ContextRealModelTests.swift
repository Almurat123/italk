import Foundation
import Testing
import AgentRuntime
import AppleSkills
import MLX
import MLXProvider

// CONTEXT MEMORY
// Updated: 2026-10-31
// Status: verified (Mac, Qwen3.5-2B 4-bit); device numbers come from the app's -contextProbe
// Why: The on-device context window was a guess (a manifest number, 4,096) and the prompt was sized by a character estimate. These tests use the real model:
//      (1) the exact prompt count must equal what the model consumed, (2) how prefill time and GPU memory grow with the prompt, so the runtime window can
//      be chosen from measurements, (3) the owner's failing request end to end through the real runner with thinking on.
// Debug Goal: Prove the counter is exact, find the real memory and time cost of a longer window, and show the failing request now completes.
// Search Tags: context window memory prefill curve exact token count qwen3.5 mlx probe
// Invariants:
// - Needs a real GPU (macOS or a device); disabled on the simulator.
// - ITALK_MODEL_DIR=<model folder>; ITALK_CONTEXT_CURVE=<json out> for the curve; ITALK_CONTEXT_OWNER=<json out> for the end-to-end run.
// Failure Modes:
// - The curve's peak memory is cumulative within the process (peak only grows): lengths run in ascending order so each row's peak belongs to its length.

#if targetEnvironment(simulator)
private let realModelAvailable = false
#else
private let realModelAvailable = true
#endif
private let env = ProcessInfo.processInfo.environment

private func artifact(_ dir: URL, window: Int) -> ModelArtifact {
    ModelArtifact(id: dir.lastPathComponent, displayName: dir.lastPathComponent, version: "ctx", license: "apache-2.0", baseModelLicense: "apache-2.0", files: [],
                  residentBytes: 1_800_000_000, kvBytesPerToken: 12_288, contextTokens: window, maxAutonomy: .restrictedTools, autonomySource: "context probe")
}

/// Pseudo-text of about `tokens` tokens (Chinese sentences with numbers, so it is neither trivially repetitive nor pathological).
private func filler(paragraphs n: Int) -> String {
    (0..<n).map { "第\($0)段：今天杭州天气不错，最高二十五度，适合出门走走，不过早晚有点凉，记得带件外套；会议改到下午\($0 % 12 + 1)点。" }.joined(separator: "\n")
}

private func request(paragraphs n: Int) -> GenerationRequest {
    GenerationRequest(messages: [ModelMessage(role: .system, text: "你是 iTalk 普通话助手。"), ModelMessage(role: .user, text: filler(paragraphs: n) + "\n用一个字回答：好。")],
                      tools: [], maxTokens: 1, temperature: 0, reasoning: false)
}

@Test(.enabled(if: realModelAvailable && env["ITALK_MODEL_DIR"] != nil && env["ITALK_CONTEXT_CURVE"] != nil))
func exactCountAndPrefillCurveWithRealModel() async throws {
    let dir = URL(fileURLWithPath: env["ITALK_MODEL_DIR"]!)
    let provider = MLXModelProvider(artifact: artifact(dir, window: 262_144), directory: dir)       // no window policy: this measures what the runtime can do
    try await provider.prepare { _ in }
    let loaded = MLX.Memory.snapshot()
    var rows: [[String: Any]] = []
    var mismatches = 0
    for target in [1024, 2048, 4096, 6144, 8192, 12_288, 16_384, 24_576, 32_768] {
        // Grow the text until the exact count reaches the target (about 3% tolerance).
        var paragraphs = max(4, target / 38)
        var counted = await provider.promptTokenCount(request(paragraphs: paragraphs)) ?? 0
        for _ in 0..<6 where abs(counted - target) > target / 33 {
            paragraphs = max(2, Int(Double(paragraphs) * Double(target) / Double(max(counted, 1))))
            counted = await provider.promptTokenCount(request(paragraphs: paragraphs)) ?? 0
        }
        let started = ContinuousClock.now
        var used = 0, firstToken = 0.0
        for try await event in provider.generate(request(paragraphs: paragraphs)) {
            if case .usage(let u) = event { used = u.promptTokens; firstToken = u.firstTokenLatency ?? 0 }
        }
        let wall = (ContinuousClock.now - started).components
        let seconds = Double(wall.seconds) + Double(wall.attoseconds) / 1e18
        let mem = MLX.Memory.snapshot()
        if used != counted { mismatches += 1 }
        let row: [String: Any] = ["target": target, "counted": counted, "modelUsed": used, "firstTokenSeconds": firstToken, "wallSeconds": seconds,
                                  "prefillTokensPerSecond": firstToken > 0 ? Double(used) / firstToken : 0,
                                  "activeMB": mem.activeMemory / 1_048_576, "peakMB": mem.peakMemory / 1_048_576, "cacheMB": mem.cacheMemory / 1_048_576,
                                  "peakAboveLoadedMB": (mem.peakMemory - loaded.peakMemory) / 1_048_576]
        rows.append(row)
        print("CURVE target=\(target) counted=\(counted) used=\(used) ttft=\(String(format: "%.2f", firstToken))s prefill=\(Int(Double(used) / max(firstToken, 0.001))) tok/s active=\(mem.activeMemory / 1_048_576)MB peak=\(mem.peakMemory / 1_048_576)MB")
    }
    let out: [String: Any] = ["model": dir.lastPathComponent, "weightsActiveMB": loaded.activeMemory / 1_048_576, "rows": rows, "countMismatches": mismatches,
                              "kvBytesPerTokenDeclared": 12_288, "device": ProcessInfo.processInfo.machineHardwareName]
    try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: env["ITALK_CONTEXT_CURVE"]!))
    #expect(mismatches == 0, "the exact counter must equal the prompt tokens the model actually consumed")
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size); sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// The skill the UI session added, read from the app source so the test sees the shipped text (full instructions and short form).
private func generativeUISkill() throws -> Skill {
    // A macOS test process may not read ~/Documents (privacy sandbox): ITALK_GENUI_SOURCE points at a copy of the file outside it.
    if let copy = env["ITALK_GENUI_SOURCE"] { return try parseGenerativeUISkill(URL(fileURLWithPath: copy)) }
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("apps/iOS/GenerativeUISkill.swift").path) { url.deleteLastPathComponent() }
    return try parseGenerativeUISkill(url.appendingPathComponent("apps/iOS/GenerativeUISkill.swift"))
}

private func parseGenerativeUISkill(_ file: URL) throws -> Skill {
    let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    func block(_ name: String) -> String? {
        guard let open = lines.firstIndex(where: { $0.contains("static let \(name) = #\"\"\"") }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "\"\"\"#" }) else { return nil }
        let indent = lines[close].prefix { $0 == " " }.count
        return lines[(open + 1)..<close].map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }
    let summaryLine = lines.first { $0.contains("summary: \"") }!
    let a = summaryLine.range(of: "summary: \"")!, b = summaryLine.range(of: "\"", range: a.upperBound..<summaryLine.endIndex)!
    return Skill(id: "generative_ui", name: "交互界面", summary: String(summaryLine[a.upperBound..<b.lowerBound]), instructions: block("instructions")!, toolNames: [], brief: block("brief"))
}

@Test(.enabled(if: realModelAvailable && env["ITALK_MODEL_DIR"] != nil && env["ITALK_CONTEXT_OWNER"] != nil))
func ownersRequestWithRealModelThinkingOn() async throws {
    let dir = URL(fileURLWithPath: env["ITALK_MODEL_DIR"]!)
    let window = Int(env["ITALK_WINDOW"] ?? "4096") ?? 4096
    let provider = MLXModelProvider(artifact: artifact(dir, window: window), directory: dir)
    try await provider.prepare { _ in }
    var reg = ToolRegistry([DateTimeTool(), CalculatorTool()]), cat = SkillCatalog([SkillCatalog.standard.skill("core")!])
    AppleSkills.install(into: &reg, catalog: &cat, context: AppleSkillContext(presenter: E2EUI(), filesRoot: FileManager.default.temporaryDirectory))
    var all = SkillCatalog([SkillCatalog.standard.skill("core")!]); all.add(WebSkill.skill); all.add(cat.skills); all.add(try generativeUISkill())
    var results: [[String: Any]] = []
    for (name, prompt, thinking) in [("owner request, thinking on", "渲染几个选择题出来我看看你的skills", true), ("owner request, thinking off", "渲染几个选择题出来我看看你的skills", false),
                                     ("plain chat, thinking on", "你好，用一句话介绍你自己", true)] {
        let runner = AgentRunner(provider: provider, tools: reg, skills: all, store: InMemoryRunStore(), permissions: StaticPermissionAuthority())
        await runner.setReasoning(thinking)
        let began = ContinuousClock.now
        let id = try await runner.start(conversationId: UUID(), text: prompt)
        await runner.waitUntilIdle(id)
        let run = await runner.snapshot(id)!
        let seconds = Double((ContinuousClock.now - began).components.seconds)
        let answer = run.messages.last { $0.role == .assistant && $0.toolCalls.isEmpty }?.text ?? ""
        let hasUI = answer.contains("```italk-ui")
        var uiValid = false
        if hasUI, let open = answer.range(of: "```italk-ui\n"), let close = answer.range(of: "\n```", range: open.upperBound..<answer.endIndex) {
            uiValid = (try? JSONSerialization.jsonObject(with: Data(answer[open.upperBound..<close.lowerBound].utf8))) != nil
        }
        let reports = (run.contextReports ?? []).map { r -> [String: Any] in ["kind": r.kind, "step": r.step, "window": r.window, "prompt": r.promptTokens, "exact": r.exact, "answerRoom": r.reservedOutput,
            "thinking": r.thinking, "system": r.systemTokens, "skills": r.skillTokens, "memory": r.memoryTokens, "tools": r.toolSchemaTokens, "history": r.historyTokens, "run": r.runTokens,
            "attempts": r.attempts, "outcome": r.outcome, "ms": r.millis] }
        results.append(["name": name, "state": run.state.rawValue, "failure": run.failure ?? "", "failureDetail": run.failureDetail ?? "", "seconds": seconds, "loadedSkills": run.loadedSkills,
                        "modelSteps": run.modelSteps, "answerChars": answer.count, "containsUI": hasUI, "uiJSONValid": uiValid, "reports": reports,
                        "usage": run.usage.map { ["prompt": $0.promptTokens, "completion": $0.completionTokens, "ttft": $0.firstTokenLatency ?? 0] }])
        print("OWNER \(name): state=\(run.state.rawValue) failure=\(run.failure ?? "-") steps=\(run.modelSteps) ui=\(hasUI) valid=\(uiValid) seconds=\(Int(seconds)) prompts=\(run.usage.map(\.promptTokens))")
        #expect(run.state == .completed, "\(name): \(run.failure ?? "") \(run.failureDetail ?? "")")
    }
    try JSONSerialization.data(withJSONObject: ["window": window, "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: env["ITALK_CONTEXT_OWNER"]!))
}
