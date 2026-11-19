import SwiftUI
import AgentRuntime

/// Skills browser over the runtime's global registry (SkillRegistryCenter). Nothing here decides which skills a model may use;
/// the switch only hides a skill from every model and makes its tools refuse to run.
struct SkillsHubView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, enabled, attention, remote
        var id: String { rawValue }
        var title: String { switch self { case .all: "全部"; case .enabled: "已启用"; case .attention: "需处理"; case .remote: "来自电脑" } }
    }
    @Environment(SkillRegistryCenter.self) private var center
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var filter = Filter.all

    private func needsAttention(_ s: SkillInfo) -> Bool {
        guard s.enabled else { return false }
        if !s.blockedBy.isEmpty { return true }
        switch s.permission { case .denied, .restricted, .unavailable, .notDetermined: return true; default: return false }
    }

    private var skills: [SkillInfo] {
        center.skills.filter { skill in
            guard query.isEmpty || skill.name.localizedCaseInsensitiveContains(query) || skill.summary.localizedCaseInsensitiveContains(query) else { return false }
            switch filter {
            case .all: return true
            case .enabled: return skill.enabled
            case .attention: return needsAttention(skill)
            case .remote: if case .remote = skill.source { return true } else { return false }
            }
        }
    }

    /// Grouped by the first privacy capability a skill depends on; skills with none are "通用".
    private var groups: [(title: String, items: [SkillInfo])] {
        Dictionary(grouping: skills) { $0.capabilities.first?.label ?? "通用" }
            .map { (title: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.title == "通用" ? false : $1.title == "通用" ? true : $0.title < $1.title }
    }

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { skill in
                        NavigationLink { SkillDetailScreen(id: skill.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: skill.symbol).font(.title3).frame(width: 34, height: 34)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(skill.enabled ? Color.primary : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name).foregroundStyle(skill.enabled ? Color.primary : Color.secondary)
                                    Text(skill.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                SkillPermissionBadge(skill: skill)
                            }
                        }.accessibilityIdentifier("skill.\(skill.id)")
                    }
                }
            }
            if skills.isEmpty {
                if center.isRefreshing && center.skills.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                else if query.isEmpty { ContentUnavailableView(filter == .all ? "没有可用的技能" : "没有符合条件的技能", systemImage: "sparkles") }
                else { ContentUnavailableView.search(text: query) }
            }
            Section {
                Label("导入技能", systemImage: "square.and.arrow.down").foregroundStyle(.secondary)
                Label("浏览技能库", systemImage: "square.grid.2x2").foregroundStyle(.secondary)
                NavigationLink { AllowedActionsView() } label: { Label("已允许的操作", systemImage: "checkmark.shield") }
            } header: { Text("管理") } footer: {
                Text("技能的安装、更新和删除尚未开放。电脑端提供的技能连接后会自动出现在这里。")
            }
        }
        .searchable(text: $query, prompt: "搜索技能")
        .navigationTitle("技能").navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await center.refresh() } } }
        .refreshable { await center.refresh() }
    }
}

/// A short state chip. Colour is secondary information; the text always says what is wrong.
struct SkillPermissionBadge: View {
    let skill: SkillInfo
    var body: some View {
        if !skill.enabled { chip("已关闭", .secondary) }
        else if !skill.blockedBy.isEmpty { chip("已被隐私开关关闭", .orange) }
        else {
            switch skill.permission {
            case .notRequired, .granted: EmptyView()
            case .limited: chip("部分授权", .secondary)
            case .notDetermined: chip("未授权", .secondary)
            case .denied: chip("被拒绝", .orange)
            case .restricted: chip("受限制", .orange)
            case .unavailable: chip("不可用", .orange)
            case .unknownByDesign: chip("无法确认", .secondary)
            }
        }
    }
    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
    }
}

struct SkillDetailScreen: View {
    let id: String
    @Environment(SkillRegistryCenter.self) private var center

    var body: some View {
        if let skill = center.skill(id) {
            List {
                Section {
                    LabeledContent("来源", value: { if case .remote = skill.source { return "来自电脑" } else { return "内置" } }())
                    if !skill.capabilities.isEmpty { LabeledContent("涉及", value: skill.capabilities.map(\.label).joined(separator: "、")) }
                }
                Section {
                    Text(skill.summary)
                    if center.instructions(id) != nil {
                        NavigationLink { SkillTextEditor(id: id) } label: {
                            LabeledContent("查看与编辑说明", value: center.hasCustomText(id) ? "已自定义" : "")
                        }
                        .accessibilityIdentifier("skill.instructions")
                    }
                    Toggle("启用", isOn: Binding(get: { skill.enabled }, set: { center.setEnabled(skill.id, $0) }))
                        .accessibilityIdentifier("skill.enabled")
                } footer: { Text("关闭后，所有模型都看不到这个技能，它的工具也不会运行。") }

                if skill.permission != .notRequired || !skill.blockedBy.isEmpty {
                    Section("权限") {
                        Text(skill.permissionDetail).font(.subheadline).foregroundStyle(.secondary)
                        if !skill.blockedBy.isEmpty {
                            Button("在 iTalk 中重新开启所需开关", systemImage: "switch.2") { center.enableBlockedCapabilities(for: skill.id) }
                        }
                        switch skill.permission {
                        case .notDetermined:
                            Button("请求系统权限", systemImage: "hand.raised") { Task { await center.requestPermission(for: skill.id) } }
                        case .denied, .restricted:
                            Button("前往系统设置", systemImage: "gear") { center.openSystemSettings() }
                        default: EmptyView()
                        }
                    }
                }

                if !skill.tools.isEmpty {
                    Section("包含的工具") {
                        ForEach(skill.tools) { tool in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(tool.title)
                                    Spacer()
                                    Text(tool.risk.title).font(.caption2.weight(.medium))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(tool.risk == .sensitive ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(tool.risk == .sensitive ? Color.red : Color.secondary)
                                }
                                Text(tool.asksBeforeRunning ? "运行前会询问你" : "无需询问").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !skill.limitations.isEmpty { Section("系统限制") { Text(skill.limitations).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(skill.name).navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("找不到这个技能", systemImage: "questionmark.circle")
        }
    }
}

/// The editable text is an on-device override; permissions and the original skill package remain unchanged.
struct SkillTextEditor: View {
    let id: String
    @Environment(SkillRegistryCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @State private var summary = ""
    @State private var instructions = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section("简介") {
                TextField("向模型介绍这个技能", text: $summary, axis: .vertical)
                    .lineLimit(2...5).accessibilityIdentifier("skill.editor.summary")
            }
            Section {
                TextEditor(text: $instructions)
                    .frame(minHeight: 240)
                    .accessibilityIdentifier("skill.editor.instructions")
            } header: { Text("技能说明") } footer: {
                Text("模型会使用这里的说明。修改保存在这台设备上，不会更改工具权限或原始技能包。")
            }
            if center.hasCustomText(id) {
                Section {
                    Button("恢复原始说明", role: .destructive) {
                        saving = true
                        Task {
                            do { try await center.resetText(id); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }
                }
            }
        }
        .navigationTitle("技能说明").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    saving = true
                    Task {
                        do { try await center.saveText(id: id, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }
                .disabled(saving || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("skill.editor.save")
            }
        }
        .task(id: center.skill(id)?.id) {
            guard let skill = center.skill(id), let text = center.instructions(id) else { return }
            summary = skill.summary; instructions = text
        }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
