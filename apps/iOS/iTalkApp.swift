import SwiftUI

@main struct iTalkApp: App {
    @State private var model = AppModel()
    @State private var localModels: LocalModelCenter
    @State private var library = ConversationLibrary(historyEnabled: false)
    @State private var neuralVoice: NeuralVoiceCenter
    @State private var neuralOutput: NeuralSpeechOutput?
    @State private var activity = AgentActivityController()
    // Claude contracts (see WORK_COORDINATION.md): one object per UI-facing domain.
    @State private var modelCenter: ModelCenter
    @State private var skillRegistry = SkillRegistryCenter()
    @State private var accountCenter = AccountCenter()
    @State private var remoteDevices = RemoteDeviceCenter()
    @State private var memoryCenter = MemoryCenter()

    init() {
        let local = LocalModelCenter(), voices = NeuralVoiceCenter()
        _localModels = State(initialValue: local)
        _neuralVoice = State(initialValue: voices)
        _modelCenter = State(initialValue: ModelCenter(local: local, voices: voices))
    }

    /// Claude hook: one skill/tool registry, permission authority and runner for every model and conversation.
    @MainActor private func connectAgentPlatform() {
        let platform = AgentPlatform.shared
        let lib = library
        memoryCenter.bind(platform: platform)
        platform.configure(memory: memoryCenter.hooks(),
            attachmentURL: { id in await lib.attachmentFile(id) },
            searchConversations: { q in await lib.search(q).map { ($0.conversation.id, $0.conversation.title, $0.snippet) } })
        platform.recordFinal = { [weak lib] tag, text, failed, cancelled, modelId in
            guard let lib, let turn = UUID(uuidString: tag) else { return }
            await lib.recordAssistant(turnId: turn, text: text, final: !failed && !cancelled, failed: failed, modelId: modelId, sessionOnly: false)
        }
        platform.loadTraces()
        let models = localModels
        lib.willDelete = { [weak models] id in models?.cancel(conversationId: id) }
        model.lifecycle = { [weak models] background in
            Task { @MainActor in
                if background { await platform.didEnterBackground(localModel: !(models?.usesCloud ?? false)) }
                else { await platform.willEnterForeground() }
            }
        }
        activity.track(model: model, platform: platform)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-skillEditorFixture") {
                    NavigationStack { SkillTextEditor(id: "core") }
                } else {
                    AssistantView()
                }
                #else
                AssistantView()
                #endif
            }
                .environment(model).environment(localModels).environment(library).environment(neuralVoice)
                .environment(modelCenter).environment(skillRegistry).environment(accountCenter).environment(remoteDevices).environment(memoryCenter)
                .task {
                    #if DEBUG || ITALK_PROBES
                    // The Mac-link probe needs nothing else to be ready, so it starts before the model/skill refreshes below (some of which wait on hardware the simulator lacks).
                    let probeArguments = ProcessInfo.processInfo.arguments
                    if let i = probeArguments.firstIndex(of: "-remoteProbe"), probeArguments.indices.contains(i + 1) {
                        let link = probeArguments[i + 1]
                        let workspace = probeArguments.firstIndex(of: "-remoteProbeWorkspace").flatMap { probeArguments.indices.contains($0 + 1) ? probeArguments[$0 + 1] : nil }
                        Task { try? await Task.sleep(for: .seconds(2)); await RemoteProbe.run(center: remoteDevices, link: link, workspace: workspace) }
                    }
                    if probeArguments.contains("-remoteProbeFinish") {
                        Task { try? await Task.sleep(for: .seconds(2)); await RemoteProbe.finish(center: remoteDevices) }
                    }
                    #endif
                    #if DEBUG && !targetEnvironment(simulator)
                    // CONTEXT MEMORY
                    // Updated: 2026-10-28
                    // Status: inferred
                    // Why: A tethered developer can provision a temporary test gateway without embedding credentials in the app.
                    // Debug Goal: Provision the explicitly requested developer test account without embedding credentials.
                    // Search Tags: debug device test gateway provisioning keychain
                    // Invariants:
                    // - Release builds never accept launch-environment credentials.
                    // - Cloud consent is enabled only for an explicitly provisioned test launch.
                    // Failure Modes:
                    // - Reconfiguring the same endpoint resets existing consent unnecessarily.
                    let testEnvironment = ProcessInfo.processInfo.environment
                    if let endpoint = testEnvironment["ITALK_TEST_ENDPOINT"], let token = testEnvironment["ITALK_TEST_TOKEN"],
                       endpoint != model.archive.preferences.endpoint || token != model.token {
                        do { try model.configure(endpoint: endpoint, token: token) }
                        catch { model.message = error.localizedDescription }
                    }
                    if let endpoint = testEnvironment["ITALK_TEST_ENDPOINT"], let token = testEnvironment["ITALK_TEST_TOKEN"],
                       endpoint == model.archive.preferences.endpoint, token == model.token {
                        model.setGrant(.cloudAI, allowed: true)
                    }
                    #endif
                    library.setHistoryEnabled(model.grants.contains(.history))
                    localModels.library = library
                    model.localChat = localModels
                    model.conversationBackend = library
                    model.companion = { CompanionSignalHub.shared.note($0) }
                    connectAgentPlatform()
                    accountCenter.bind(model: model, local: localModels)
                    remoteDevices.account = accountCenter
                    await memoryCenter.load(legacy: model.archive.memories)
                    await modelCenter.refresh()
                    await skillRegistry.refresh()
                    await accountCenter.refresh()
                    #if DEBUG && !targetEnvironment(simulator)
                    if let token = testEnvironment["ITALK_DEV_CLOUD_SESSION"] {
                        do { try await accountCenter.provisionDeveloperSession(token) }
                        catch { model.message = error.localizedDescription }
                    }
                    #endif
                    #if DEBUG && !targetEnvironment(simulator)
                    if let endpoint = testEnvironment["ITALK_TEST_ENDPOINT"], let token = testEnvironment["ITALK_TEST_TOKEN"],
                       endpoint == model.archive.preferences.endpoint, token == model.token {
                        await model.refreshAccount()
                        localModels.updateCloudModels(model.account?.models ?? [])
                        if let flash = model.account?.models?.first(where: { $0.id == "deepseek-flash" && $0.available }) {
                            localModels.selectCloud(flash)
                        }
                    }
                    #endif
                    #if DEBUG || ITALK_PROBES
                    if ProcessInfo.processInfo.arguments.contains("-captureProbe") {
                        Task { try? await Task.sleep(for: .seconds(2)); await CaptureProbe.run() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-contextProbe") {
                        Task { await ContextProbe.run(models: localModels) }
                    }
                    #endif
                    if ProcessInfo.processInfo.arguments.contains("-agentAcceptance") {
                        Task { try? await Task.sleep(for: .seconds(2)); await AcceptanceRunner(models: localModels, library: library).runAll() }
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    // UI fixtures must not open a hardware audio graph on simulator launch.
                    let uiOnly = ProcessInfo.processInfo.arguments.contains("-chatLayoutFixture")
                        || ProcessInfo.processInfo.arguments.contains("-characterPreview")
                    #else
                    let uiOnly = false
                    #endif
                    if !uiOnly {
                        let output = NeuralSpeechOutput(center: neuralVoice); neuralOutput = output
                        model.neuralSpeech = output
                        #if DEBUG || ITALK_PROBES
                        if ProcessInfo.processInfo.arguments.contains("-ttsProbe") {
                            Task { try? await Task.sleep(for: .seconds(2)); await TTSProbe.run(center: neuralVoice, output: output) }
                        }
                        #endif
                    }
                    await library.importLegacy(model.archive.history)
                }
                .onChange(of: model.grants.contains(.history)) { _, on in library.setHistoryEnabled(on) }
                .onOpenURL { _ in }   // italk://open from the Live Activity only brings the app forward
        }
    }
}
