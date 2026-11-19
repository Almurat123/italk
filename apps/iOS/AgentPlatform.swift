import Foundation
import Observation
import UIKit
import WebKit
import MessageUI
import UniformTypeIdentifiers
import Network
import WatchConnectivity
import os
import AgentRuntime
import AppleSkills
import AssistantCore

/// iTalk's own per-capability switches (Settings › 隐私与权限). Independent of system authorization, which is checked live
/// on every tool call. Everything is on by default except sharing personal or health data with cloud models.
@MainActor @Observable final class CapabilitySettings {
    static let key = "italk.capabilities.disabled"
    static let skillsKey = "italk.skills.disabled"
    private(set) var disabled: Set<String>
    /// Skills the person switched off in the skill list: hidden from every model, and their tools refuse to run.
    private(set) var disabledSkills: Set<String>
    init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [Capability.cloudPersonalData.rawValue, Capability.cloudHealthData.rawValue])
        disabledSkills = Set(UserDefaults.standard.stringArray(forKey: Self.skillsKey) ?? [])
    }
    func isSkillOn(_ id: String) -> Bool { !disabledSkills.contains(id) }
    func setSkill(_ id: String, _ on: Bool) {
        if on { disabledSkills.remove(id) } else { disabledSkills.insert(id) }
        UserDefaults.standard.set(Array(disabledSkills), forKey: Self.skillsKey)
    }
    func isOn(_ c: Capability) -> Bool { c == .runtime || !disabled.contains(c.rawValue) }
    func set(_ c: Capability, _ on: Bool) {
        if on { disabled.remove(c.rawValue) } else { disabled.insert(c.rawValue) }
        UserDefaults.standard.set(Array(disabled), forKey: Self.key)
    }
    /// Switches shown to the person (Codex renders them).
    static let userFacing: [Capability] = [.calendar, .reminders, .alarms, .notifications, .health, .location, .maps, .weather, .contacts, .communication,
        .photos, .camera, .vision, .files, .documents, .audio, .media, .home, .sensors, .device, .bluetooth, .nfc, .clipboard, .apps, .shortcuts,
        .web, .translation, .memory, .thirdPartySkills, .cloudPersonalData, .cloudHealthData]
}

// MARK: - System UI for tools

/// Presents the system sheets some tools need. Visual style is the system's own; the tool only learns the outcome.
@MainActor final class UIKitSystemPresenter: NSObject, SystemPresenter, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate,
                                            UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    private var resultContinuation: CheckedContinuation<String, Never>?
    private var urlContinuation: CheckedContinuation<URL?, Never>?
    private let filesRoot: URL
    init(filesRoot: URL) { self.filesRoot = filesRoot }

    private var top: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    func open(_ url: URL) async -> Bool {
        if url.scheme == "app-settings" { return await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
        return await UIApplication.shared.open(url)
    }
    func canOpen(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }

    func composeMessage(recipients: [String], body: String) async -> String {
        guard MFMessageComposeViewController.canSendText(), let top else { return "unavailable" }
        let vc = MFMessageComposeViewController(); vc.recipients = recipients; vc.body = body; vc.messageComposeDelegate = self
        return await withCheckedContinuation { c in resultContinuation = c; top.present(vc, animated: true) }
    }
    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let r = result == .sent ? "sent" : result == .cancelled ? "cancelled" : "failed"
        MainActor.assumeIsolated { controller.dismiss(animated: true); resultContinuation?.resume(returning: r); resultContinuation = nil }
    }

    func composeMail(to: [String], subject: String, body: String) async -> String {
        guard MFMailComposeViewController.canSendMail(), let top else { return "unavailable" }
        let vc = MFMailComposeViewController(); vc.setToRecipients(to); vc.setSubject(subject); vc.setMessageBody(body, isHTML: false); vc.mailComposeDelegate = self
        return await withCheckedContinuation { c in resultContinuation = c; top.present(vc, animated: true) }
    }
    nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let r = result == .sent ? "sent" : result == .cancelled ? "cancelled" : result == .saved ? "cancelled" : "failed"
        MainActor.assumeIsolated { controller.dismiss(animated: true); resultContinuation?.resume(returning: r); resultContinuation = nil }
    }

    func capturePhoto() async -> URL? {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), let top else { return nil }
        let vc = UIImagePickerController(); vc.sourceType = .camera; vc.delegate = self
        return await withCheckedContinuation { c in urlContinuation = c; top.present(vc, animated: true) }
    }
    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        MainActor.assumeIsolated {
            picker.dismiss(animated: true)
            var url: URL?
            if let data = image?.jpegData(compressionQuality: 0.85) {
                let dir = filesRoot.appendingPathComponent("相机", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                let u = dir.appendingPathComponent("IMG-\(f.string(from: .now)).jpg")
                if (try? data.write(to: u, options: .completeFileProtection)) != nil { url = u }
            }
            urlContinuation?.resume(returning: url); urlContinuation = nil
        }
    }
    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        MainActor.assumeIsolated { picker.dismiss(animated: true); urlContinuation?.resume(returning: nil); urlContinuation = nil }
    }

    func pickDocument() async -> URL? {
        guard let top else { return nil }
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); vc.delegate = self
        return await withCheckedContinuation { c in urlContinuation = c; top.present(vc, animated: true) }
    }
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated { urlContinuation?.resume(returning: urls.first); urlContinuation = nil }
    }
    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { urlContinuation?.resume(returning: nil); urlContinuation = nil }
    }

    func share(_ file: URL) async -> Bool {
        guard let top else { return false }
        let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        return await withCheckedContinuation { c in
            vc.completionWithItemsHandler = { _, done, _, _ in c.resume(returning: done) }
            top.present(vc, animated: true)
        }
    }

    func setScreenBrightness(_ value: Double) -> Bool {
        guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return false }
        screen.brightness = CGFloat(min(1, max(0, value))); return true
    }
    func screenBrightness() -> Double? { (UIApplication.shared.connectedScenes.first as? UIWindowScene).map { Double($0.screen.brightness) } }
}

/// Renders JavaScript pages for `open_webpage` in a non-persistent WKWebView (no cookies, no stored data, never shown).
final class WebKitPageRenderer: PageRenderer, @unchecked Sendable {
    func render(_ url: URL) async throws -> (html: String, finalURL: URL) {
        try await MainActor.run { RenderJob() }.run(url)
    }
    @MainActor final class RenderJob: NSObject, WKNavigationDelegate {
        private var web: WKWebView?
        private var done: CheckedContinuation<Void, Error>?
        func run(_ url: URL) async throws -> (html: String, finalURL: URL) {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            w.customUserAgent = WebHTTP.userAgent; w.navigationDelegate = self; web = w
            try await withCheckedThrowingContinuation { c in
                done = c; w.load(URLRequest(url: url, timeoutInterval: 15))
                Task { @MainActor in try? await Task.sleep(for: .seconds(18)); self.finish(nil) }
            }
            try await Task.sleep(for: .milliseconds(1200))      // let client-side rendering settle
            let html = (try await w.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
            let final = w.url ?? url
            web = nil
            return (html, final)
        }
        private func finish(_ error: Error?) { guard let d = done else { return }; done = nil; if let error { d.resume(throwing: error) } else { d.resume() } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let u = action.request.url, WebSafety.check(u) == nil else { return .cancel }
            return .allow
        }
    }
}

// MARK: - Memory as tools (user-approved long-term memory)

struct MemoryHooks: Sendable {
    enum SaveResult: Sendable { case saved(id: String), merged(id: String), refused(String) }
    var enabled: @Sendable @MainActor () -> Bool
    var save: @Sendable @MainActor (String) async -> SaveResult
    var search: @Sendable @MainActor (String) async -> [(id: String, text: String)]
    var update: @Sendable @MainActor (_ id: String, _ text: String) async -> Bool
    var forget: @Sendable @MainActor (_ id: String) async -> Bool
    /// Where every run reads relevant long-term memory from (all models share it).
    var source: (any MemoryContextSource)?
    /// Called with the person's own message before a turn: learns what they say about themselves, if learning is on.
    var learn: @Sendable @MainActor (_ text: String, _ conversationId: UUID) async -> Void = { _, _ in }
}

enum MemoryTools {
    static func make(_ hooks: MemoryHooks) -> [any AgentTool] {
        let off = "长期记忆未开启：iTalk 设置 › 记忆"
        return [Fn(ToolSpec(name: "memory_save", description: "把用户明确要求记住的事保存为长期记忆（需要用户确认）", parameters: [
            "content": ParamSpec(.string, "要记住的内容（用户的原意，一句话，简洁）", maxLength: 500)
        ], permission: .confirmBeforeAction, capability: .memory, dataClass: .personal), describe: { a in "保存记忆：\(a["content"]?.string ?? "")" }) { a in
            let content = a["content"]?.string ?? ""
            guard await MainActor.run(body: { hooks.enabled() }) else { throw ToolFailure(off, retryable: false) }
            switch await hooks.save(content) {
            case .saved(let id): return ToolOutput(value: .object(["saved": .bool(true), "id": .string(id)]), summary: "已保存记忆", externalId: id)
            case .merged(let id): return ToolOutput(value: .object(["saved": .bool(true), "id": .string(id), "note": .string("已有相同的记忆，已更新")]), summary: "已更新记忆", externalId: id)
            case .refused(let why): throw ToolFailure(why, retryable: false)
            }
        },
         Fn(ToolSpec(name: "memory_search", description: "查找用户批准保存的长期记忆", parameters: [
            "query": ParamSpec(.string, "关键词，可为空表示最近的记忆", required: false, maxLength: 100)
         ], permission: .readOnly, capability: .memory, dataClass: .personal)) { a in
            guard await MainActor.run(body: { hooks.enabled() }) else { throw ToolFailure(off, retryable: false) }
            let q = a["query"]?.string ?? ""
            let hits = await hooks.search(q)
            return ToolOutput(value: .object(["memories": .array(hits.prefix(10).map { .object(["id": .string($0.id), "text": .string($0.text)]) })]), summary: "\(hits.count) 条记忆")
         },
         Fn(ToolSpec(name: "memory_update", description: "修改一条已保存的长期记忆（先用 memory_search 找到 id）", parameters: [
            "id": ParamSpec(.string, "memory_search 返回的记忆 id", maxLength: 64),
            "content": ParamSpec(.string, "修改后的完整内容", maxLength: 500)
         ], permission: .confirmBeforeAction, capability: .memory, dataClass: .personal), describe: { a in "修改记忆：\(a["content"]?.string ?? "")" }) { a in
            guard await MainActor.run(body: { hooks.enabled() }) else { throw ToolFailure(off, retryable: false) }
            guard await hooks.update(a["id"]?.string ?? "", a["content"]?.string ?? "") else { throw ToolFailure("没有找到这条记忆，或内容不能保存", retryable: false) }
            return ToolOutput(value: .object(["updated": .bool(true)]), summary: "已修改记忆", externalId: a["id"]?.string)
         },
         Fn(ToolSpec(name: "memory_forget", description: "删除一条已保存的长期记忆（先用 memory_search 找到 id）", parameters: [
            "id": ParamSpec(.string, "memory_search 返回的记忆 id", maxLength: 64)
         ], permission: .confirmBeforeAction, capability: .memory, dataClass: .personal), describe: { _ in "删除一条记忆" }) { a in
            guard await MainActor.run(body: { hooks.enabled() }) else { throw ToolFailure(off, retryable: false) }
            guard await hooks.forget(a["id"]?.string ?? "") else { throw ToolFailure("没有找到这条记忆", retryable: false) }
            return ToolOutput(value: .object(["forgotten": .bool(true)]), summary: "已删除记忆", externalId: a["id"]?.string)
         }]
    }
    struct Fn: AgentTool {
        let spec: ToolSpec
        let describeFn: (@Sendable (JSONValue) -> String)?
        let run: @Sendable (JSONValue) async throws -> ToolOutput
        init(_ spec: ToolSpec, describe: (@Sendable (JSONValue) -> String)? = nil, _ run: @escaping @Sendable (JSONValue) async throws -> ToolOutput) {
            self.spec = spec; self.describeFn = describe; self.run = run
        }
        func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput { try await run(arguments) }
        func describe(_ arguments: JSONValue) -> String { describeFn?(arguments) ?? spec.description }
    }
    static let skill = Skill(id: "memory", name: "长期记忆", summary: "保存与查找用户批准的长期记忆",
        instructions: "只有用户明确要求“记住”时才用 memory_save（会请用户确认）；用户要求修改或忘记某件事时，先 memory_search 找到 id，再用 memory_update / memory_forget；回答前需要了解用户偏好时可用 memory_search。密码、证件号、银行卡号不会被保存。",
        toolNames: ["memory_save", "memory_search", "memory_update", "memory_forget"], limitations: "密码、证件号、银行卡号和密钥不会被记住；健康相关内容需用户单独允许后才会提供给云端模型。")
}

// MARK: - The platform

/// One registry of skills and tools, one permission authority, one execution journal and one runner for every model and
/// every conversation. Conversations run independently; switching screens or models never cancels their work.
@MainActor @Observable final class AgentPlatform {
    static let shared = AgentPlatform()

    let settings = CapabilitySettings()
    /// Conversations with an unfinished run (sidebar activity indicator).
    private(set) var activeConversations: Set<UUID> = []
    /// Live streamed text per conversation (for conversations that are not on screen).
    private(set) var liveText: [UUID: String] = [:]
    /// Last measured request per conversation; this is not an estimate for an unsent draft.
    private(set) var lastContextReport: [UUID: ContextReport] = [:]
    // CONTEXT MEMORY
    // Updated: 2026-10-31
    // Status: inferred
    // Why: Terminal events from a stopped run can arrive after its replacement begins.
    // Debug Goal: Keep each run's answer and conversation activity attached to its own run.
    // Search Tags: retry old run terminal event conversation activity
    // Invariants:
    // - An older run cannot clear a newer run's activity or streaming text.
    // - Interrupted text is saved against its originating turn.
    // Failure Modes:
    // - Conversation-only tracking makes a stopped run overwrite the retry.
    // - Late terminal events hide an active conversation indicator.
    @ObservationIgnored private var activeRunByConversation: [UUID: UUID] = [:]
    @ObservationIgnored private var liveTextByRun: [UUID: String] = [:]
    /// What the agent is doing right now ("正在查询日历中的日程"), nil when only generating text. Live Activity / UI status.
    private(set) var statusLine: String?
    /// The model serving the latest turn runs off the device (personal data is filtered by the cloud privacy switches).
    private(set) var cloudInUse = false

    /// What every model sees: the built-in skills and tools plus the ones the person installed (rebuilt by `reloadInstalledSkills`).
    @ObservationIgnored private(set) var registry = ToolRegistry([DateTimeTool(), CalculatorTool()])
    @ObservationIgnored private(set) var catalog = SkillCatalog.standard
    @ObservationIgnored private var baseRegistry = ToolRegistry([DateTimeTool(), CalculatorTool()])
    @ObservationIgnored private var baseCatalog = SkillCatalog.standard
    @ObservationIgnored private let skillOverrideKey = "italk.skill.textOverrides.v1"
    @ObservationIgnored private var skillTextOverrides: [String: SkillTextOverride] = [:]
    /// Installs, updates and removes skills from other people (Application Support/iTalk/Skills). Created once the built-in tools are known.
    @ObservationIgnored private(set) var skillInstaller: SkillInstaller?
    @ObservationIgnored let skillSecrets: SkillSecretStore = KeychainSkillSecrets()
    @ObservationIgnored private let skillHTTP = URLSessionSkillHTTPClient()
    @ObservationIgnored let journal: ExecutionJournal
    /// Standing approvals, the untrusted-content rule and the audit log (Application Support/iTalk/permissions).
    @ObservationIgnored let approvalPolicy: ApprovalPolicy
    @ObservationIgnored let filesRoot: URL
    @ObservationIgnored private(set) var authority: ApplePermissionAuthority!
    @ObservationIgnored private var runner: AgentRunner?
    @ObservationIgnored private var runStore: FileRunStore?
    @ObservationIgnored private var hooked = false
    @ObservationIgnored private let log = Logger(subsystem: "com.italk.assistant", category: "agent")
    /// turn tag → writer for the final answer (set by the conversation library).
    @ObservationIgnored var recordFinal: (@MainActor (_ tag: String, _ text: String, _ failed: Bool, _ cancelled: Bool, _ modelId: String?) async -> Void)?
    @ObservationIgnored var memoryHooks: MemoryHooks?
    @ObservationIgnored var attachmentURL: (@Sendable (UUID) async -> URL?)?
    @ObservationIgnored var searchConversations: (@Sendable (String) async -> [(id: UUID, title: String, snippet: String)])?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    private init() {
        filesRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("iTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = ExecutionJournal(file: dir.appendingPathComponent("executions.json"))
        approvalPolicy = ApprovalPolicy(storeURL: dir.appendingPathComponent("permissions/grants.json"), auditURL: dir.appendingPathComponent("permissions/audit.jsonl"))
        runStore = try? FileRunStore(directory: dir.appendingPathComponent("Runs"))
        let settings = settings
        authority = ApplePermissionAuthority(switches: { c in await MainActor.run { settings.isOn(c) } })
        if let data = UserDefaults.standard.data(forKey: skillOverrideKey),
           let saved = try? JSONDecoder().decode([String: SkillTextOverride].self, from: data) { skillTextOverrides = saved }
    }

    /// Builds the registry once the app's hooks are set (memory, attachments, conversation search).
    func configure(memory: MemoryHooks, attachmentURL: @escaping @Sendable (UUID) async -> URL?,
                   searchConversations: @escaping @Sendable (String) async -> [(id: UUID, title: String, snippet: String)]) {
        memoryHooks = memory
        let memEnabled = memory.enabled
        let settings = settings
        authority = ApplePermissionAuthority(switches: { c in
            await MainActor.run { settings.isOn(c) && (c != .memory || memEnabled()) }
        })
        var reg = ToolRegistry([DateTimeTool(), CalculatorTool()])
        var cat = SkillCatalog([SkillCatalog.standard.skill("core")!])
        let ctx = AppleSkillContext(presenter: UIKitSystemPresenter(filesRoot: filesRoot), filesRoot: filesRoot,
                                    attachmentURL: attachmentURL, searchConversations: searchConversations)
        AppleSkills.install(into: &reg, catalog: &cat, context: ctx)
        let web = WebSession(renderer: WebKitPageRenderer())
        for t in WebSkill.tools(chain: .standard(mainland: true), session: web) { reg.register(t) }
        cat.add(WebSkill.skill)
        for t in MemoryTools.make(memory) { reg.register(t) }
        cat.add(MemoryTools.skill)
        cat.add(GenerativeUISkill.skill)   // UI-session hook: model-driven native interfaces (instructions only, no tools)
        baseRegistry = reg; baseCatalog = cat
        registry = reg; catalog = applyingSkillOverrides(to: cat)
        CompanionSignalHub.shared.operations.update(reg)
        let skillsDir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("iTalk/Skills", isDirectory: true)
        skillInstaller = SkillInstaller(directory: skillsDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("iTalkSkills"), builtInSkillIds: Set(cat.skills.map(\.id)),
                                        builtInToolNames: Set(reg.names), secrets: skillSecrets)
        Task { await reloadInstalledSkills() }
        startNetworkRecovery()
        if WCSession.isSupported() { WCSession.default.delegate = WatchLink.shared; WCSession.default.activate() }
    }

    /// Rebuilds the catalog and registry from the built-in set plus what is installed, and hands them to the runner (new runs use them at once).
    func reloadInstalledSkills() async {
        guard let installer = skillInstaller else { return }
        let built = InstalledSkillRuntime.build(await installer.loadAll(), client: skillHTTP, secrets: skillSecrets)
        var reg = baseRegistry, cat = baseCatalog
        for t in built.tools { reg.register(t) }
        cat.add(built.skills)
        cat = applyingSkillOverrides(to: cat)
        registry = reg; catalog = cat
        CompanionSignalHub.shared.operations.update(reg)
        await runner?.updateCatalog(tools: reg, skills: cat)
    }

    private func applyingSkillOverrides(to source: SkillCatalog) -> SkillCatalog {
        var result = source
        for skill in source.skills {
            if let custom = skillTextOverrides[skill.id] { result.add(custom.applying(to: skill)) }
        }
        return result
    }

    func hasSkillTextOverride(_ id: String) -> Bool { skillTextOverrides[id] != nil }

    // CONTEXT MEMORY
    // Updated: 2026-10-31
    // Status: inferred
    // Why: Editing an installed skill must not modify its signed package or grant extra tool permissions.
    // Debug Goal: Apply persistent local text changes to the same catalog used by the runner.
    // Search Tags: skill edit instructions summary local override reset
    // Invariants:
    // - Trust, tools, hosts and permissions come from the original skill.
    // - Reset and catalog reload restore the original package text.
    // Failure Modes:
    // - Reusing the original brief silently sends stale instructions to a small model.
    // - Updating only the settings screen leaves the model using old instructions.
    func setSkillTextOverride(_ value: SkillTextOverride?, for id: String) async throws {
        guard catalog.skill(id) != nil else { throw AppFailure.message("找不到这个技能。") }
        skillTextOverrides[id] = value
        let data = try JSONEncoder().encode(skillTextOverrides)
        UserDefaults.standard.set(data, forKey: skillOverrideKey)
        await reloadInstalledSkills()
    }

    /// The shared runner, switched to `provider` for subsequent model steps (running conversations keep their state).
    /// Whether models should reason before answering (and the reasoning be shown). Off by default: it is slower.
    private(set) var reasoningEnabled = UserDefaults.standard.bool(forKey: "italk.reasoning")
    func setReasoning(_ on: Bool) {
        reasoningEnabled = on
        UserDefaults.standard.set(on, forKey: "italk.reasoning")
        Task { await runner?.setReasoning(on) }
    }

    func runner(using provider: any ModelProvider) async -> AgentRunner? {
        cloudInUse = provider.descriptor.kind == .cloudGateway
        if let runner {
            // CONTEXT MEMORY
            // Updated: 2026-10-27
            // Status: inferred
            // Why: Two cloud providers may share a model ID but use different service credentials.
            // Debug Goal: A new turn uses the provider resolved for its current configuration.
            // Search Tags: runner cloud provider same model id credential change
            // Invariants:
            // - Provider replacement is applied even when the descriptor ID is unchanged.
            // - Existing run records and tool results remain owned by the runner.
            // Failure Modes:
            // - Comparing only model IDs reuses stale cloud credentials.
            // - Recreating the runner discards in-flight run state.
            await runner.use(provider)
            await runner.setCloudReasoning((UserDefaults.standard.string(forKey: "italk.cloud.reasoning.effort") ?? "none") != "none")
            await runner.setDisabledSkills(settings.disabledSkills)
            await runner.setMemory(memoryHooks?.source)
            return runner
        }
        guard let runStore else { return nil }
        let r = AgentRunner(provider: provider, tools: registry, skills: catalog, store: runStore, permissions: authority, journal: journal)
        runner = r
        await r.setApprovalPolicy(approvalPolicy)
        await r.setMemory(memoryHooks?.source)
        await r.setDisabledSkills(settings.disabledSkills)
        await r.setReasoning(reasoningEnabled)
        await r.setCloudReasoning((UserDefaults.standard.string(forKey: "italk.cloud.reasoning.effort") ?? "none") != "none")
        await observe(r)
        return r
    }
    var currentRunner: AgentRunner? { runner }

    private func observe(_ r: AgentRunner) async {
        guard !hooked else { return }
        hooked = true
        let events = await r.bus.subscribe(buffer: 4096)
        Task { @MainActor [weak self] in
            for await e in events {
                guard let self else { return }
                CompanionSignalHub.shared.agentEvent(e, turn: await self.turn(for: e.runId), origin: self.cloudInUse ? .cloudAgent : .localAgent)
                switch (e.type, e.payload) {
                case (.runCreated, _):
                    self.activeRunByConversation[e.conversationId] = e.runId
                    self.activeConversations.insert(e.conversationId); self.liveText[e.conversationId] = ""; self.liveTextByRun[e.runId] = ""
                    await self.record(e)
                case (.modelStarted, _):
                    self.liveTextByRun[e.runId] = ""
                    if self.activeRunByConversation[e.conversationId] == e.runId { self.liveText[e.conversationId] = "" }
                case (.modelDelta, .textDelta(let d)):
                    self.liveTextByRun[e.runId, default: ""] += d
                    if self.activeRunByConversation[e.conversationId] == e.runId { self.liveText[e.conversationId, default: ""] += d }
                case (.runResumed, _):
                    self.activeRunByConversation[e.conversationId] = e.runId
                    self.activeConversations.insert(e.conversationId)
                    await self.record(e)
                case (.toolProgress, _), (.reasoningDelta, _), (.modelCompleted, _), (.runSuspended, _): await self.record(e)
                case (.uiCreated, .component(let c)):
                    if case .approval = c.content { self.approvals[c.id.replacingOccurrences(of: "approval-", with: "")] = c }
                case (.runCompleted, _), (.runFailed, _), (.runCancelled, _):
                    await self.record(e)
                    await self.finished(e.runId, type: e.type)
                    self.liveTextByRun[e.runId] = nil
                    if self.activeRunByConversation[e.conversationId] == e.runId {
                        self.activeRunByConversation[e.conversationId] = nil; self.activeConversations.remove(e.conversationId)
                        if self.activeConversations.isEmpty { self.statusLine = nil }
                    }
                default: break
                }
            }
        }
    }

    // MARK: Trace (reasoning + execution, attached to its turn)

    /// One trace per turn id (= the user message id): the model's real reasoning (only when it provides any) and the agent's
    /// execution steps, in order, with total duration. Observable; persisted across relaunch.
    private(set) var traces: [UUID: AgentTrace] = [:]
    @ObservationIgnored private var runTurn: [UUID: UUID] = [:]
    @ObservationIgnored private var approvals: [String: UIComponent] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private lazy var timelineURL: URL = journal_dir().appendingPathComponent("traces.json")
    private func journal_dir() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("iTalk", isDirectory: true) ?? FileManager.default.temporaryDirectory
    }

    func bind(runId: UUID, turnId: UUID) { runTurn[runId] = turnId }

    private func turn(for runId: UUID) async -> UUID? {
        if let t = runTurn[runId] { return t }
        guard let tag = await runner?.snapshot(runId)?.tag, let t = UUID(uuidString: tag) else { return nil }
        runTurn[runId] = t; return t
    }

    /// Updates the turn's trace for one runtime event.
    private func record(_ e: AgentEvent) async {
        guard let turn = await turn(for: e.runId) else { return }
        var t = traces[turn] ?? AgentTrace(startedAt: e.timestamp)
        // A task resumed after a relaunch continues its clock instead of counting the time the app was gone.
        if t.state != .running && (e.type == .runCreated || e.type == .runResumed) {
            t.state = .running; t.finishedAt = nil; t.startedAt = e.timestamp.addingTimeInterval(-t.elapsed)
        }
        t.elapsed = max(t.elapsed, e.timestamp.timeIntervalSince(t.startedAt))
        switch (e.type, e.payload) {
        case (.reasoningDelta, .textDelta(let d)):
            let id = "\(e.runId.uuidString.prefix(8))-\(e.stepId)"
            if let i = t.items.lastIndex(where: { if case .reasoning(let r) = $0 { r.id == id } else { false } }), case .reasoning(var r) = t.items[i] {
                r.text += d; t.items[i] = .reasoning(r)
            } else { t.items.append(.reasoning(ReasoningBlock(id: id, text: d))) }
        case (.modelCompleted, _):
            for i in t.items.indices { if case .reasoning(var r) = t.items[i], !r.finished { r.finished = true; t.items[i] = .reasoning(r) } }
        case (.toolProgress, .activity(let a)):
            let step = AgentStep(id: a.callId, kind: AgentStep.Kind(rawValue: a.kind.rawValue) ?? .tool, state: AgentStep.State(rawValue: a.state.rawValue) ?? .running,
                title: a.title, detail: a.detail, summary: a.summary, facts: a.facts.compactMap { $0.count == 2 ? .init($0[0], $0[1]) : nil },
                sources: a.sources.enumerated().map { .init(n: $0.offset + 1, title: $0.element.title, url: $0.element.url, snippet: $0.element.snippet) },
                recovery: AgentStep.Recovery(rawValue: a.recovery.rawValue) ?? .none, permission: a.permission, symbol: a.symbol, startedAt: e.timestamp)
            if let i = t.items.firstIndex(where: { if case .step(let x) = $0 { x.id == a.callId } else { false } }), case .step(let old) = t.items[i] {
                var merged = step; merged.startedAt = old.startedAt
                if merged.detail.isEmpty { merged.detail = old.detail }
                if merged.title == a.name || merged.title.isEmpty { merged.title = old.title }
                if merged.sources.isEmpty { merged.sources = old.sources }
                if merged.state != .running && merged.state != .awaitingApproval { merged.finishedAt = e.timestamp }
                t.items[i] = .step(merged)
            } else { t.items.append(.step(step)) }
            if t.isActive && activeRunByConversation[e.conversationId] == e.runId {
                statusLine = a.state == .running ? (a.kind == .skill ? nil : a.title) : nil
            }
        case (.runCompleted, _): t.state = .finished; t.finishedAt = e.timestamp
        case (.runSuspended, _): t.state = .paused; t.finishedAt = e.timestamp
        case (.runFailed, _): t.state = .failed; t.finishedAt = e.timestamp
        case (.runCancelled, _): t.state = .cancelled; t.finishedAt = e.timestamp
        default: break
        }
        if !t.isActive {
            for i in t.items.indices {
                if case .reasoning(var block) = t.items[i], !block.finished {
                    block.finished = true; t.items[i] = .reasoning(block)
                }
            }
        }
        traces[turn] = t
        scheduleSave()
    }

    /// Rows for the permission center (iTalk switch + live iOS state).
    func permissionRows() async -> [PermissionRow] {
        await PermissionReport.rows(registry: registry, authority: authority, switches: CapabilitySettings.userFacing)
    }

    /// What the person has allowed to keep happening, newest scope first (Settings › 技能 › 已允许的操作).
    func standingGrants() async -> [ApprovalGrant] { await approvalPolicy.grants() }
    func revokeGrant(_ id: UUID) async { await approvalPolicy.revoke(id) }
    func revokeAllGrants() async { await approvalPolicy.revokeAll() }
    /// Recent tool decisions and results, for a review screen. Holds digests, never arguments.
    func recentActivity(limit: Int = 100) async -> [AuditRecord] { await approvalPolicy.recentAudit(limit: limit) }
    func clearActivityLog() async { await approvalPolicy.clearAudit() }

    /// Switches a whole skill on or off for every model. Takes effect for the next model step of running conversations too.
    func setSkillEnabled(_ id: String, _ on: Bool) {
        settings.setSkill(id, on)
        let ids = settings.disabledSkills
        Task { await runner?.setDisabledSkills(ids) }
    }

    /// "在 iTalk 中开启「X」": turns the person's own switch back on (system permissions are never changed from here).
    func enableCapability(named label: String) {
        if let c = Capability.allCases.first(where: { $0.label == label }) { settings.set(c, true) }
    }

    /// How long the person may allow a pending confirmation: always `.once`, wider only where the tool's risk allows and the run has
    /// not read untrusted content. Empty when there is no such confirmation.
    func approvalScopes(forCall callId: String) -> [ApprovalScope] {
        guard let card = approvals[callId] else { return [] }
        return card.actions.filter { $0.kind == .approve }.compactMap { $0.id == "approve" ? ApprovalScope.once : ApprovalScope(rawValue: String($0.id.dropFirst("approve.".count))) }
    }

    /// Allow with a chosen scope (`.once` = this call only).
    func respond(toApproval callId: String, scope: ApprovalScope) async -> String? {
        await respond(toApproval: callId, actionId: scope == .once ? "approve" : "approve." + scope.rawValue)
    }

    /// Approve or decline a confirmation step. The person's tap is the authorization; stale or duplicate taps are rejected by the runner.
    func respond(toApproval callId: String, approve: Bool) async -> String? {
        await respond(toApproval: callId, actionId: nil, approve: approve)
    }

    private func respond(toApproval callId: String, actionId: String?, approve: Bool = true) async -> String? {
        guard let r = runner, let card = approvals[callId] else { return "这个确认已经失效，请重新发起。" }
        guard let action = actionId.flatMap({ id in card.actions.first { $0.id == id } }) ?? card.actions.first(where: { $0.kind == (approve ? .approve : .decline) }) else { return "操作不可用" }
        do {
            try await r.submit(UIActionResponse(runId: card.runId, componentId: card.id, componentRevision: card.revision, actionId: action.id,
                                                idempotencyKey: UUID().uuidString, authorization: approve ? .userTap : .none))
            approvals[callId] = nil
            return nil
        } catch { return "确认已过期或已处理，操作没有执行。" }
    }
    var pendingApprovalCount: Int { traces.values.flatMap(\.steps).filter { $0.state == .awaitingApproval }.count }

    /// Work that was running when the process died belongs to runs that no longer exist (resumed runs flip their trace back).
    func settleOrphanedTraces(activeTurns: Set<UUID>) {
        for (turn, var t) in traces where !activeTurns.contains(turn) && (t.state == .running || t.steps.contains { $0.state == .running || $0.state == .awaitingApproval }) {
            t.items = t.items.map { item in
                switch item {
                case .step(var x): if x.state == .running || x.state == .awaitingApproval { x.state = .cancelled; if x.summary.isEmpty { x.summary = "已中断" } }; return .step(x)
                case .reasoning(var r): r.finished = true; return .reasoning(r)
                }
            }
            t.state = .cancelled; t.finishedAt = t.finishedAt ?? t.startedAt.addingTimeInterval(t.elapsed)
            traces[turn] = t
        }
        scheduleSave()
    }

    func loadTraces() {
        guard let data = try? Data(contentsOf: timelineURL), let d = try? JSONDecoder().decode([String: AgentTrace].self, from: data) else { return }
        for (k, v) in d { if let id = UUID(uuidString: k), traces[id] == nil { traces[id] = v } }
        settleOrphanedTraces(activeTurns: [])
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            var keep = self.traces.sorted { $0.value.startedAt > $1.value.startedAt }.prefix(300).map { $0 }
            // Keep the file bounded: reasoning can be long, so drop the oldest turns first.
            while keep.count > 20, let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: keep.map { ($0.key.uuidString, $0.value) })), data.count > 6_000_000 { keep.removeLast(keep.count / 4) }
            let dict = Dictionary(uniqueKeysWithValues: keep.map { ($0.key.uuidString, $0.value) })
            if let data = try? JSONEncoder().encode(dict) { try? data.write(to: self.timelineURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        }
    }

    /// Writes the final answer of every run to its conversation, whether or not that conversation is on screen.
    private func finished(_ runId: UUID, type: AgentEventType) async {
        guard let r = runner, let s = await r.snapshot(runId), let tag = s.tag else { return }
        if activeRunByConversation[s.conversationId] == runId,
           let report = s.contextReports?.last(where: { $0.kind == "step" && $0.outcome == "ok" }) {
            lastContextReport[s.conversationId] = report
        }
        let text = Self.answerText(s)
        await recordFinal?(tag, type == .runCompleted ? text : (liveTextByRun[runId] ?? text), type == .runFailed, type == .runCancelled, s.providerId)
    }

    // CONTEXT MEMORY
    // Updated: 2026-10-31
    // Status: mixed
    // Why: Small models narrate discovery and failed calls before the final response.
    // Debug Goal: Keep intermediate tool narration out of the saved answer.
    // Search Tags: final answer tool narration repeated activity
    // Invariants:
    // - The last nonempty assistant message without tool calls is the final answer.
    // - The execution trace remains available separately.
    // - Markdown and italk-ui fences survive streaming and storage for the renderer.
    // Failure Modes:
    // - Joining every assistant message repeats failed instructions in chat history.
    // - Using a speech sanitizer for display turns interactive cards into raw text.
    static func answerText(_ s: RunSnapshot) -> String {
        let mine = s.messages.dropFirst(s.contextCount ?? 0).filter { $0.role == .assistant && $0.toolCalls.isEmpty }
        return mine.map(\.text).last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
    }

    // MARK: Lifecycle

    /// Leaving the foreground: on-device model steps park (GPU work is not allowed in the background) and resume on return.
    func didEnterBackground(localModel: Bool) async {
        guard localModel, let r = runner else { return }
        for s in await r.activeRuns() where s.state == .running { await r.suspend(s.runId) }
    }
    func willEnterForeground() async {
        guard let r = runner else { return }
        for s in await r.activeRuns() where s.state == .awaitingForeground || s.state == .awaitingNetwork { await r.resume(s.runId) }
    }
    /// After a relaunch: unfinished runs from the previous process continue (side effects are reconciled, never repeated).
    func resumeInterrupted() async {
        guard let r = runner else { return }
        for s in await r.activeRuns() {
            if let tag = s.tag, let t = UUID(uuidString: tag) { runTurn[s.runId] = t }
            // A confirmation left over from the previous process is stale: nothing was executed, so close it.
            if s.state == .awaitingApproval { await r.cancel(s.runId) } else { await r.resume(s.runId) }
        }
    }

    private func startNetworkRecovery() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let r = self?.runner else { return }
                for s in await r.activeRuns() where s.state == .awaitingNetwork { await r.resume(s.runId) }
            }
        }
        m.start(queue: .global(qos: .utility)); pathMonitor = m
    }

    /// For docs/diagnostics: skills, tools and what Apple does not expose.
    var catalogSummary: (skills: Int, tools: Int) { (catalog.skills.count, registry.names.count) }
}

/// Activates WatchConnectivity so `watch_status` reports the real pairing state.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
