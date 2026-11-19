import Foundation
import UIKit
import AgentRuntime
import AppleSkills
import AssistantCore

/// On-device acceptance run through the PRODUCTION stack (shared registry, live permission authority, execution journal, runner,
/// event → trace pipeline). Launch with `-agentAcceptance`; writes Documents/acceptance-report.json.
/// A scripted model calls the tools so each tool path is tested on its own; the last cases use the real installed model.
/// Cases that need the person (a system permission prompt) are reported as "needs you", never as passed.
@MainActor final class AcceptanceRunner {
    struct Result: Codable {
        var name: String
        var status: String            // pass / fail / needs-you
        var detail: String
        var seconds: Double
        var trace: String = ""
    }
    private var results: [Result] = []
    private let platform = AgentPlatform.shared
    private let models: LocalModelCenter
    private let library: ConversationLibrary

    init(models: LocalModelCenter, library: ConversationLibrary) { self.models = models; self.library = library }

    private func scripted(_ steps: [ScriptedModelProvider.Step]) -> ScriptedModelProvider { ScriptedModelProvider(descriptor: .scripted(), steps: steps) }
    private func call(_ id: String, _ name: String, _ args: [String: JSONValue] = [:]) -> ScriptedModelProvider.Step {
        .init([.toolCall(ToolCall(id: id, name: name, arguments: .object(args))), .completed(.toolCalls)])
    }
    private func say(_ s: String) -> ScriptedModelProvider.Step { .init([.textDelta(s), .usage(Usage(promptTokens: 1, completionTokens: 1)), .completed(.stop)]) }

    /// Runs one scripted case on the shared runner and returns the finished trace.
    private func run(_ name: String, steps: [ScriptedModelProvider.Step], prompt: String = "验收", wait: Double = 60, approve: Bool? = nil,
                     check: @escaping (AgentTrace, RunSnapshot) -> (Bool, String)) async {
        let t0 = ContinuousClock.now
        func elapsed() -> Double { let d = (ContinuousClock.now - t0).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
        let model = scripted(steps)
        guard let runner = await platform.runner(using: model) else { add(name, "fail", "runner unavailable", elapsed()); return }
        await runner.use(model)          // the runner is shared: every case needs its own script (all scripted models share one id)
        let conv = UUID(), turn = UUID()
        do {
            let id = try await runner.start(conversationId: conv, context: [ModelMessage(role: .user, text: prompt)], tag: turn.uuidString)
            platform.bind(runId: id, turnId: turn)
            var blocked = false
            while elapsed() < wait {
                try await Task.sleep(for: .milliseconds(250))
                guard let s = await runner.snapshot(id) else { break }
                if s.state.isTerminal { break }
                if s.state == .awaitingApproval {
                    guard let approve else { blocked = true; break }
                    // The same path the on-screen buttons use.
                    if let callId = s.pending?.callId { _ = await platform.respond(toApproval: callId, approve: approve) }
                }
            }
            try await Task.sleep(for: .milliseconds(400))
            let snap = await runner.snapshot(id)
            let trace = platform.traces[turn] ?? AgentTrace()
            let summary = trace.items.map { item -> String in
                switch item {
                case .reasoning(let r): return "思考(\(r.text.count)字)"
                case .step(let s): return "\(s.title)[\(s.state.rawValue)]\(s.summary.isEmpty ? "" : " " + s.summary.prefix(60))"
                }
            }.joined(separator: " → ") + " | " + trace.summaryTitle
            if blocked || (snap?.state.isTerminal == false) {
                add(name, "needs-you", "等待你在手机上点按系统弹窗或确认卡片（\(trace.steps.last?.title ?? "")）", elapsed(), summary)
            } else if let snap {
                let (ok, detail) = check(trace, snap)
                add(name, ok ? "pass" : "fail", detail, elapsed(), summary)
            }
            await runner.cancel(id)
        } catch { add(name, "fail", "\(error)", elapsed()) }
    }

    private func add(_ name: String, _ status: String, _ detail: String, _ seconds: Double, _ trace: String = "") {
        results.append(Result(name: name, status: status, detail: detail, seconds: (seconds * 10).rounded() / 10, trace: trace))
        save()
    }
    private func save() {
        let url = platform.filesRoot.appendingPathComponent("acceptance-report.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(results) { try? data.write(to: url, options: .atomic) }
    }

    func runAll() async {
        results = []
        // On-device model work only runs in the foreground: keep the screen on so the run is not paused by auto-lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        // 1. Permission truth: every row as the person would read it.
        let rows = await platform.permissionRows()
        add("权限状态", rows.count > 15 ? "pass" : "fail", rows.map { "\($0.capability.rawValue)=\($0.switchOn ? "开" : "关")/\(String(describing: $0.state))" }.joined(separator: ", "), 0)

        // 2. Health through the live permission gate (first request shows the system prompt).
        let before = rows.first { $0.capability == .health }
        add("健康-请求前状态", "pass", "\(String(describing: before?.state)) — \(before?.statusText ?? "")", 0)
        await run("健康-步数", steps: [call("h1", "load_skill", ["id": .string("health")]), call("h2", "health_query", ["metric": .string("steps")]), say("好")], wait: 25) { t, _ in
            let s = t.steps.first { $0.id == "h2" }
            return (s?.state == .succeeded || s?.state == .needsPermission, "step=\(s?.state.rawValue ?? "none") \(s?.summary ?? "")")
        }
        // 3. Alarm: created, read back from the system, then removed.
        await run("闹钟-10:00", steps: [call("a1", "load_skill", ["id": .string("alarms")]), call("a2", "alarm_set", ["time": .string("10:00"), "label": .string("iTalk验收")]), say("好")], wait: 25) { t, _ in
            let s = t.steps.first { $0.id == "a2" }
            return (s?.state == .succeeded && s?.summary.contains("核对") == true, "step=\(s?.state.rawValue ?? "none") \(s?.summary ?? "")")
        }
        // Remove what the test created (directly through the registered tools, like the agent would).
        let ctx = ToolContext(runId: UUID(), callId: "cleanup", idempotencyKey: "acceptance/cleanup/\(UUID())", now: .now)
        if let list = try? await platform.registry.tool(named: "alarm_list")?.execute(.object([:]), context: ctx), let alarms = list.value["alarms"]?.array {
            var removed = 0
            for a in alarms where a["time"]?.string == "10:00" {
                if let id = a["id"]?.string, (try? await platform.registry.tool(named: "alarm_cancel")?.execute(.object(["id": .string(id)]), context: ctx)) != nil { removed += 1 }
            }
            let left = (try? await platform.registry.tool(named: "alarm_list")?.execute(.object([:]), context: ctx))?.value["alarms"]?.array?.count ?? -1
            add("闹钟-清理", left == 0 ? "pass" : "fail", "已取消 \(removed) 个测试闹钟，剩余 \(left) 个", 0)
        }
        // 4. Internet from this phone and this network.
        await run("联网搜索", steps: [call("w1", "load_skill", ["id": .string("web")]), call("w2", "web_search", ["query": .string("今日热点新闻")]), say("好")], wait: 40) { t, _ in
            let s = t.steps.first { $0.id == "w2" }
            return (s?.state == .succeeded && (s?.sources.count ?? 0) > 0, "step=\(s?.state.rawValue ?? "none") sources=\(s?.sources.count ?? 0) \(s?.summary ?? "")")
        }
        await run("打开网页", steps: [call("w1", "open_webpage", ["url": .string("https://www.gov.cn/")]), say("好")], wait: 40) { t, _ in
            let s = t.steps.first { $0.id == "w1" }
            return (s?.state == .succeeded, "step=\(s?.state.rawValue ?? "none") \(s?.summary ?? "")")
        }
        await run("天气", steps: [call("t1", "load_skill", ["id": .string("weather")]), call("t2", "weather_forecast", ["place": .string("杭州"), "days": .number(2)]), say("好")], wait: 40) { t, _ in
            let s = t.steps.first { $0.id == "t2" }
            return (s?.state == .succeeded && !(s?.facts.isEmpty ?? true) || s?.state == .needsPermission, "step=\(s?.state.rawValue ?? "none") \(s?.summary ?? "")")
        }
        await run("设备状态", steps: [call("d1", "device_status"), call("d2", "network_status"), say("好")], wait: 15) { t, _ in
            (t.steps.count == 2 && t.steps.allSatisfy { $0.state == .succeeded }, t.steps.map(\.summary).joined(separator: "; "))
        }
        // 5. Confirmation flow with the same code path as the on-screen buttons (writes only inside iTalk's own folder).
        try? FileManager.default.removeItem(at: platform.filesRoot.appendingPathComponent("验收/确认.md"))
        await run("确认卡-允许", steps: [call("f1", "files_write", ["path": .string("验收/确认.md"), "content": .string("ok")]), say("好")], wait: 30, approve: true) { t, _ in
            let ok = FileManager.default.fileExists(atPath: self.platform.filesRoot.appendingPathComponent("验收/确认.md").path)
            return (ok && t.steps.first?.state == .succeeded, "file=\(ok) step=\(t.steps.first?.state.rawValue ?? "none")")
        }
        try? FileManager.default.removeItem(at: platform.filesRoot.appendingPathComponent("验收/拒绝.md"))
        await run("确认卡-拒绝", steps: [call("f1", "files_write", ["path": .string("验收/拒绝.md"), "content": .string("no")]), say("好的，没有写入。")], wait: 30, approve: false) { t, _ in
            let exists = FileManager.default.fileExists(atPath: self.platform.filesRoot.appendingPathComponent("验收/拒绝.md").path)
            return (!exists && t.steps.first?.state == .declined, "file=\(exists) step=\(t.steps.first?.state.rawValue ?? "none")")
        }
        // 6. A tool of a skill that was never loaded (small models skip load_skill): loads implicitly.
        await run("隐式加载", steps: [call("n1", "network_status"), say("好")], wait: 15) { t, s in (t.steps.first?.state == .succeeded && s.loadedSkills.contains("device"), "loaded=\(s.loadedSkills)") }
        // 7. Real model, real tools, no script.
        guard models.isAvailable else { add("真实模型", "fail", "没有可用的模型", 0); return }
        for (name, prompt, reasoning) in [("真实模型-热点(含思考)", "今天最热门的事情是什么", true), ("真实模型-步数", "我今天走了多少步", false)] {
            let t0 = ContinuousClock.now
            do {
                let provider = try await models.activeProvider()
                guard let runner = await platform.runner(using: provider) else { continue }
                await runner.setReasoning(reasoning)
                let turn = UUID(), conv = UUID()
                let id = try await runner.start(conversationId: conv, context: [ModelMessage(role: .user, text: prompt)], tag: turn.uuidString)
                platform.bind(runId: id, turnId: turn)
                var waited = 0.0
                while waited < 150 { try await Task.sleep(for: .milliseconds(500)); waited += 0.5; if let s = await runner.snapshot(id), s.state.isTerminal { break } }
                try await Task.sleep(for: .milliseconds(500))
                let snap = await runner.snapshot(id); let trace = platform.traces[turn] ?? AgentTrace()
                let secs = Double((ContinuousClock.now - t0).components.seconds)
                let finished = snap?.state == .completed
                let detail = "state=\(snap?.state.rawValue ?? "?") steps=\(snap?.modelSteps ?? 0) tools=\(snap?.toolCalls ?? 0) reasoning=\(trace.hasReasoning) answer=\((snap?.finalText ?? "").prefix(120))"
                let summary = trace.items.map { item -> String in switch item { case .reasoning(let r): "思考(\(r.text.count)字)"; case .step(let s): "\(s.title)[\(s.state.rawValue)] \(s.summary.prefix(50))" } }.joined(separator: " → ") + " | " + trace.summaryTitle
                let needs = snap?.state == .running && trace.steps.contains { $0.state == .needsPermission || $0.state == .awaitingApproval }
                add(name, finished ? "pass" : (needs ? "needs-you" : "fail"), detail, secs, summary)
                await runner.setReasoning(platform.reasoningEnabled)
                await runner.cancel(id)
            } catch { add(name, "fail", "\(error)", 0) }
        }
        add("完成", "pass", "共 \(results.count) 项", 0)
    }
}

#if DEBUG || ITALK_PROBES
// CONTEXT MEMORY
// Updated: 2026-10-31
// Status: inferred
// Why: A scripted model cannot establish whether the phone's real tokenizer and runtime fit the reported short request.
// Debug Goal: Exercise the installed local model and failure continuity without writing test turns into the person's history.
// Search Tags: device context probe qwen overflow continue failed turn token counts memory
// Invariants:
// - Only the explicitly selected local Qwen 3.5 2B model is used; preferences are not changed.
// - The report contains counts and state only, never user memories or generated text.
// - Start GPU inference only while the app is active in the foreground.
// Failure Modes:
// - A cloud-selected model would make a phone test look like local inference.
// - A pending approval or stalled model must not be reported as a completed answer.
@MainActor enum ContextProbe {
    private struct CaseReport: Codable {
        var name: String
        var state: String
        var failure: String?
        var seconds: Double
        var modelSteps: Int
        var answerCharacters: Int
        var promptTokens: [Int]
        var completionTokens: [Int]
        var reports: [ContextReport]
    }

    private struct Report: Codable {
        var status = "starting"
        var modelId: String
        var window = 0
        var physicalMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000)
        var availableBeforeMB = Int(os_proc_available_memory() / 1_000_000)
        var footprintBeforeMB = 0
        var peakFootprintMB = 0
        var minimumAvailableMB = Int(os_proc_available_memory() / 1_000_000)
        var failureHistoryPreserved: Bool?
        var cases: [CaseReport] = []
    }

    static func run(models: LocalModelCenter) async {
        var report = Report(modelId: models.selected.id)
        report.footprintBeforeMB = footprint()
        report.peakFootprintMB = report.footprintBeforeMB
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("context-probe.json")
        func save() {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) { try? data.write(to: url, options: .atomic) }
        }
        func sample() {
            report.peakFootprintMB = max(report.peakFootprintMB, footprint())
            let available = Int(os_proc_available_memory() / 1_000_000)
            if available > 0 { report.minimumAvailableMB = report.minimumAvailableMB > 0 ? min(report.minimumAvailableMB, available) : available }
        }
        save()
        guard !models.usesCloud, models.selected.id == "qwen3.5-2b-4bit" else { report.status = "select_qwen_2b_local"; save(); return }
        guard UIApplication.shared.applicationState == .active else { report.status = "foreground_required"; save(); return }
        let idleWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleWasDisabled }
        do {
            report.status = "loading"; save()
            let provider = try await models.activeProvider()
            report.window = provider.descriptor.capabilities.contextWindow
            sample()
            guard UIApplication.shared.applicationState == .active else { report.status = "foreground_required"; save(); return }
            let platform = AgentPlatform.shared
            let runner = AgentRunner(provider: provider, tools: platform.registry, skills: platform.catalog, store: InMemoryRunStore(), permissions: platform.authority)
            await runner.setMemory(platform.memoryHooks?.source)
            await runner.setDisabledSkills(platform.settings.disabledSkills)
            await runner.setReasoning(true)
            let question = "渲染几个选择题出来我看看你的skills"
            let store = try ConversationStore(directory: nil)
            let conversation = try await store.createConversation()
            _ = try await store.append(ConversationMessage(conversationId: conversation.id, role: .user, parts: [.text(question)]))
            _ = try await store.append(ConversationMessage(conversationId: conversation.id, role: .assistant, parts: [.text("")], status: .failed))
            _ = try await store.append(ConversationMessage(conversationId: conversation.id, role: .user, parts: [.text("继续")]))
            let context = try await ContextManager(store: store).build(conversationId: conversation.id,
                budget: ContextBudget(contextWindow: report.window, reservedOutput: 512, reservedTools: 1200), supportsVision: false)
            report.failureHistoryPreserved = context.messages.contains { $0.role == .user && $0.text == question }
                && context.messages.contains { $0.role == .assistant && $0.text == ContextManager.unfinishedNote }
                && context.messages.last?.text == "继续"
            for (name, messages) in [("owner_request", [ModelMessage(role: .user, text: question)]), ("continue_after_failure", context.messages)] {
                guard UIApplication.shared.applicationState == .active else { report.status = "foreground_required"; save(); return }
                report.status = name; save()
                let started = Date()
                let id = try await runner.start(conversationId: UUID(), context: messages)
                var snapshot: RunSnapshot?
                while Date().timeIntervalSince(started) < 180 {
                    sample()
                    snapshot = await runner.snapshot(id)
                    if snapshot?.state.isTerminal == true || snapshot?.state == .awaitingApproval { break }
                    if UIApplication.shared.applicationState != .active {
                        await runner.cancel(id); report.status = "foreground_lost"; save(); return
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                if snapshot?.state.isTerminal != true { await runner.cancel(id) }
                let failure = snapshot?.failure.map { $0 == "context_too_large" ? "context_too_large" : "other" }
                report.cases.append(CaseReport(name: name, state: snapshot?.state.rawValue ?? "missing", failure: failure,
                    seconds: Date().timeIntervalSince(started), modelSteps: snapshot?.modelSteps ?? 0,
                    answerCharacters: snapshot?.finalText?.count ?? 0, promptTokens: snapshot?.usage.map(\.promptTokens) ?? [],
                    completionTokens: snapshot?.usage.map(\.completionTokens) ?? [], reports: snapshot?.contextReports ?? []))
                sample(); save()
            }
            report.status = "completed"; save()
        } catch {
            sample(); report.status = "probe_error"; save()
        }
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
    }
}
#endif
