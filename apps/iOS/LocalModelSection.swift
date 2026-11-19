import SwiftUI
import AgentRuntime

// CONTEXT MEMORY
// Updated: 2026-10-27
// Status: inferred
// Why: The catalog and download lifecycle are owned by the runtime, not the UI.
// Debug Goal: Keep model selection and download state tied to the selected artifact.
// Search Tags: model center selection download state cloud availability
// Invariants:
// - Never display an unconfigured cloud model as available.
// - The downloader operates on center.selected only.
// Failure Modes:
// - Switching during a download may be rejected by the runtime.
// - Catalog capability claims may differ from the installed implementation.
struct ModelCenterView: View {
    @Environment(LocalModelCenter.self) private var center
    @Environment(AppModel.self) private var model
    @Environment(AccountCenter.self) private var accountCenter
    @AppStorage(NeuralVoiceCenter.voiceKey) private var voiceId = "moss-yunshu"
    @Environment(RemoteDeviceCenter.self) private var remote
    private let cards = ModelCenterCatalog.cards()
    private var localCards: [ModelCard] { cards.filter { $0.id != "italk-cloud" } }
    private var multimodalCards: [ModelCard] { localCards.filter { $0.advertised.contains(.vision) } }
    private var voiceName: String { NeuralVoiceCenter.displayName(for: voiceId) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前使用").font(.caption).foregroundStyle(.secondary)
                    Text(center.displayName).font(.title3.weight(.semibold))
                    Label(center.isAvailable ? "可用于对话" : "尚未就绪", systemImage: center.isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Section {
                NavigationLink { ModelListPage(title: "本地文本模型", cards: localCards, empty: "没有可用的本地模型。") } label: {
                    SettingsRow("本地文本模型", "iphone", value: "\(localCards.count) 个")
                }.accessibilityIdentifier("models.local")
                NavigationLink { ModelListPage(title: "多模态模型", cards: multimodalCards, empty: "当前没有声明图片理解的设备端模型。") } label: {
                    SettingsRow("多模态模型", "photo.on.rectangle", value: "\(multimodalCards.count) 个")
                }
                NavigationLink { ImageModelsPage() } label: { SettingsRow("图像模型", "paintbrush.pointed", value: "暂无") }
                NavigationLink { VoiceModelsPage() } label: { SettingsRow("语音模型", "waveform", value: voiceName) }
                    .accessibilityIdentifier("models.voice")
            } header: { Text("设备端") }
            Section {
                NavigationLink { CloudServiceView() } label: {
                    SettingsRow("iTalk 云端", "cloud", value: accountCenter.availability == .available ? "可用" : "未开放")
                }
                NavigationLink { RemoteDevicesView() } label: { SettingsRow("我的电脑", "laptopcomputer", value: remote.hasDevices ? (remote.onlineCount > 0 ? "已连接" : "未连接") : "未添加") }
            } header: { Text("联网") }
            ForEach(remote.devices.filter { !$0.models.isEmpty }) { device in
                Section {
                    ForEach(device.models) { item in
                        NavigationLink { RemoteDeviceDetailView(id: device.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text(item.supportsTools ? "可用于电脑任务" : "仅对话 · 不支持工具")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.state.isOnline ? "在线" : "离线")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text(device.name) }
            }
        }
        .navigationTitle("模型中心").navigationBarTitleDisplayMode(.inline)
        .task {
            if !model.archive.preferences.endpoint.isEmpty && !model.token.isEmpty { await model.refreshAccount() }
            center.updateCloudModels(model.account?.models ?? [])
        }
        .onChange(of: model.account?.models) { _, models in center.updateCloudModels(models ?? []) }
    }
}

/// Compact capability glyphs. Solid = verified in iTalk, dim = advertised or implemented but not verified. Details live on the model page.
struct ModelCapabilityStrip: View {
    let card: ModelCard
    static func symbol(_ value: ModelCard.Capability) -> String {
        switch value { case .text: "text.bubble"; case .vision: "photo"; case .tools: "wrench.and.screwdriver"; case .reasoning: "brain"; case .longContext: "text.alignleft"; case .multilingual: "character.bubble" }
    }
    private func verified(_ c: ModelCard.Capability) -> Bool { if case .verified = card.inITalk[c] { true } else { false } }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ModelCard.Capability.allCases.filter { card.advertised.contains($0) }, id: \.rawValue) { c in
                Image(systemName: Self.symbol(c)).font(.caption)
                    .foregroundStyle(verified(c) ? Color.primary : Color.secondary.opacity(0.5))
            }
        }.accessibilityHidden(true)
    }
}

private struct ModelListPage: View {
    @Environment(LocalModelCenter.self) private var center
    @Environment(ModelCenter.self) private var modelCenter
    let title: String, cards: [ModelCard], empty: String
    var body: some View {
        List {
            if cards.isEmpty { ContentUnavailableView(empty, systemImage: "cube.transparent") }
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink { ModelDetailsView(card: card) } label: {
                      HStack(spacing: 12) {
                        Text(String(card.developer.prefix(1))).font(.headline).frame(width: 38, height: 38)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.headline)
                            Text("\(card.parameters) · \(card.quantization) · \(ByteCountFormatter.string(fromByteCount: card.downloadBytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                            ModelCapabilityStrip(card: card)
                        }
                        Spacer()
                        if !center.usesCloud && center.selected.id == card.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                      }.padding(.vertical, 4)
                    }
                    if let entry = modelCenter.entry(card.id) { ModelDownloadControl(entry: entry) }
                }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct ImageModelsPage: View {
    var body: some View {
        List {
            ContentUnavailableView {
                Label("暂无图像模型", systemImage: "paintbrush.pointed")
            } description: { Text("iTalk 目前没有可用的图像生成模型。上线后会在这里下载和管理。") }
        }.navigationTitle("图像模型").navigationBarTitleDisplayMode(.inline)
    }
}

private struct VoiceModelsPage: View {
    @Environment(ModelCenter.self) private var modelCenter
    var body: some View {
        List {
            NavigationLink { VoiceSettingsView() } label: { SettingsRow("设备端声音", "waveform") }
            NavigationLink { DownloadsListView(title: "声音下载", entries: modelCenter.voiceModels) } label: { SettingsRow("声音下载与管理", "arrow.down.circle") }
        }.navigationTitle("语音模型").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CloudModelDetailsView: View {
    @Environment(LocalModelCenter.self) private var center
    let cloud: GatewayCloudModel
    var body: some View {
        List {
            Section {
                LabeledContent("接口名称", value: cloud.id)
                LabeledContent("状态", value: cloud.available ? "服务已配置" : "不可用")
                LabeledContent("图片处理", value: cloud.supportsImages ? "服务已开放" : "服务未开放")
                Picker("思考强度", selection: Binding(get: { center.cloudReasoningEffort }, set: { center.setCloudReasoningEffort($0) })) {
                    Text("关闭").tag("none")
                    Text("低").tag("low")
                    Text("高").tag("high")
                    Text("最高").tag("max")
                }.disabled(center.localSwitchBlocked || !cloud.available)
                Text("思考强度越高，可能需要更多时间和额度；语音对话保持快速模式。") .font(.footnote).foregroundStyle(.secondary)
                if !cloud.note.isEmpty { Text(cloud.note).font(.footnote).foregroundStyle(.secondary) }
                Button(center.usesCloud && center.selectedCloudId == cloud.id ? "当前模型" : "在对话中使用") {
                    center.selectCloud(cloud)
                }.disabled(!cloud.available || !center.cloudAvailable || center.localSwitchBlocked || (center.usesCloud && center.selectedCloudId == cloud.id))
            }
        }.navigationTitle(cloud.name)
    }
}

private struct ModelDetailsView: View {
    @Environment(LocalModelCenter.self) private var center
    @Environment(AppModel.self) private var model
    let card: ModelCard
    private var isCloud: Bool { card.id == "italk-cloud" }
    private var isSelected: Bool { isCloud ? center.usesCloud : !center.usesCloud && center.selected.id == card.id }
    private var localSelectionBlocked: Bool {
        guard !isCloud && center.selected.id != card.id else { return false }
        if center.localSwitchBlocked { return true }
        switch center.state { case .downloading, .verifying: return true; default: return false }
    }
    var body: some View {
        List {
            Section {
                Text(card.developer).foregroundStyle(.secondary)
                LabeledContent("运行位置", value: card.runsOn)
                if isCloud {
                    LabeledContent("实际模型", value: model.account?.model ?? "尚未获取")
                    if let configured = model.account?.modelConfigured {
                        LabeledContent("服务状态", value: configured ? "已配置" : "未配置或账户不可用")
                    }
                    if let maximum = model.account?.maxOutputTokens {
                        LabeledContent("单次输出上限", value: "\(maximum) tokens")
                    }
                    if let images = model.account?.supportsImages {
                        LabeledContent("图片处理", value: images ? "服务已开放" : "服务未开放")
                    }
                }
                if !isCloud {
                    LabeledContent("参数", value: card.parameters)
                    LabeledContent("量化", value: card.quantization)
                    LabeledContent("下载大小", value: ByteCountFormatter.string(fromByteCount: card.downloadBytes, countStyle: .file))
                    LabeledContent("模型内存", value: ByteCountFormatter.string(fromByteCount: card.memoryBytes, countStyle: .memory))
                    LabeledContent("模型声明的上下文", value: card.advertisedContext)
                    LabeledContent("iTalk 上下文", value: "\(card.iTalkContextTokens) tokens")
                    LabeledContent("许可", value: card.license)
                }
                Button(isSelected ? "当前模型" : "在对话中使用") {
                    if isCloud { center.setUsesCloud(true) }
                    else if let artifact = center.options.first(where: { $0.id == card.id }) {
                        center.select(artifact)
                        if center.selected.id == artifact.id { center.setUsesCloud(false) }
                    }
                }.disabled(isSelected || (isCloud && (!center.cloudAvailable || center.localSwitchBlocked)) || localSelectionBlocked || (center.usesCloud && center.localSwitchBlocked))
                if isCloud && !center.cloudAvailable { Text("服务未连接或尚未允许云端处理。").font(.footnote).foregroundStyle(.secondary) }
                if localSelectionBlocked { Text("请等待当前任务或模型载入完成，并暂停当前下载后再切换。").font(.footnote).foregroundStyle(.secondary) }
            }
            if !isCloud && center.selected.id == card.id { LocalModelSection() }
            Section("能力") {
                ForEach(ModelCard.Capability.allCases, id: \.rawValue) { capability in
                    if let status = card.inITalk[capability] {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(label(capability), systemImage: symbol(capability))
                            Text(capability == .reasoning && !isCloud
                                 ? "设备端可在模型管理中开启；语音对话不使用。"
                                 : description(status)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !card.performance.isEmpty {
                Section("性能参考") {
                    ForEach(card.performance, id: \.label) { measure in
                        VStack(alignment: .leading, spacing: 3) {
                            LabeledContent(measure.label, value: measure.value)
                            Text(measure.context).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
    }
    private func label(_ value: ModelCard.Capability) -> String {
        switch value { case .text: "文字"; case .vision: "图片理解"; case .tools: "工具"; case .reasoning: "思考"; case .longContext: "长上下文"; case .multilingual: "多语言" }
    }
    private func symbol(_ value: ModelCard.Capability) -> String {
        switch value { case .text: "text.bubble"; case .vision: "photo"; case .tools: "wrench.and.screwdriver"; case .reasoning: "brain"; case .longContext: "text.alignleft"; case .multilingual: "character.bubble" }
    }
    private func description(_ value: ModelCard.Status) -> String {
        switch value { case .verified(let note): "已验证 · \(note)"; case .implementedUnverified(let note): "待验证 · \(note)"; case .notImplemented(let note): "暂不可用 · \(note)" }
    }
}

/// Settings section for the on-device model. Visual style is Codex's to refine; state semantics live in `LocalModelCenter`.
struct LocalModelSection: View {
    @Environment(LocalModelCenter.self) private var center
    @State private var confirmDownload = false
    @State private var confirmDelete = false

    var body: some View {
        Section {
            switch center.state {
            case .downloading(let fraction, _):
                DownloadProgressRow(fraction: fraction, done: center.downloadedBytes, total: center.selected.totalBytes,
                                    speed: center.bytesPerSecond, remaining: center.secondsRemaining, note: center.sourceNote)
                    .accessibilityIdentifier("localModel.progress")
                Button("暂停", role: .cancel) { center.cancelDownload() }
            case .verifying:
                LabeledContent("状态") { ProgressView().controlSize(.small) }
            case .notInstalled, .failed:
                if case .failed(let reason) = center.state { Text(reason).font(.footnote).foregroundStyle(.red) }
                Button(center.downloadedBytes > 0 ? "继续下载（\(size(center.downloadedBytes)) / \(size(center.selected.totalBytes))）"
                                                  : "下载（\(size(center.selected.totalBytes))）") { confirmDownload = true }
                    .disabled(center.switchingModel)
                    .accessibilityIdentifier("localModel.download")
            case .installed, .ready, .loading:
                LabeledContent("状态", value: center.state == .loading ? "正在载入" : "已就绪")
                    .accessibilityIdentifier("localModel.status")
                Button("删除模型", role: .destructive) { confirmDelete = true }
                    .disabled(center.localSwitchBlocked).accessibilityIdentifier("localModel.remove")
            }
            if let note = center.deviceNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
            ReasoningToggle()
        } header: { Text("本地模型") } footer: {
            Text("下载后可离线使用，免费。")
        }
        .confirmationDialog("下载「\(center.selected.displayName)」？", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("下载") { center.download() }
        }
        .confirmationDialog("删除「\(center.selected.displayName)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { center.remove() }
        } message: { Text("删除后需要重新下载才能使用。") }
    }

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

struct DownloadProgressRow: View {
    let fraction: Double
    let done: Int64?, total: Int64?
    let speed: Double?, remaining: Double?, note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("正在下载")
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
            if let done, let total {
                HStack {
                    Text("\(fmt(done)) / \(fmt(total))")
                    Spacer()
                    Text(rate)
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if let total, total > 0 {
                Text("总大小 \(fmt(total))").font(.footnote).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var rate: String {
        guard let speed, speed > 0 else { return "正在连接…" }
        let s = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
        guard let remaining else { return s }
        return s + " · 剩余 " + Self.eta(remaining)
    }
    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func eta(_ t: Double) -> String {
        if t < 60 { return "不到 1 分钟" }
        let m = Int((t / 60).rounded(.up))
        return m < 60 ? "约 \(m) 分钟" : "约 \(m / 60) 小时 \(m % 60) 分钟"
    }
}

/// Thinking mode. Models that can reason stream their real reasoning into the conversation; others show nothing extra.
struct ReasoningToggle: View {
    @State private var platform = AgentPlatform.shared
    var body: some View {
        Toggle("显示模型的思考过程", isOn: Binding(get: { platform.reasoningEnabled }, set: { platform.setReasoning($0) }))
            .accessibilityIdentifier("agent.reasoning.toggle")
        Text("开启后，支持思考的模型会先思考再回答，思考内容实时显示在对话里，回答会慢一些、更耗电。语音对话不使用。不支持思考的模型（部分云端模型）不会显示任何思考内容，iTalk 也不会替它编造。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
