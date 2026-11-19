import SwiftUI
import AssistantCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var deleteAll = false
    @State private var exportURL: URL?
    #if os(iOS)
    @State private var showModelCenter = false
    #endif
    #if DEBUG && os(iOS)
    @State private var showMessagePreview = ProcessInfo.processInfo.arguments.contains("-messagePreview")
    #endif
    var body: some View {
        #if os(iOS)
        SettingsHome()
        #else
        legacyBody
        #endif
    }
    private var legacyBody: some View {
        NavigationStack {
            Form {
                Section("语音") {
                    Toggle("打开 App 后开始听", isOn: preference(\.autoListen))
                    Toggle("朗读回答", isOn: preference(\.speakResponses))
                    LabeledContent("语言", value: "普通话")
                }
                #if os(iOS)
                Section {
                    Button { showModelCenter = true } label: {
                        HStack {
                            Label("模型中心", systemImage: "square.stack.3d.up")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle()).foregroundStyle(.primary)
                    }.accessibilityIdentifier("settings.modelCenter")
                }
                #if DEBUG
                Section("开发者预览") {
                    NavigationLink {
                        MessagePreviewView()
                    } label: {
                        Label("模型消息样式测试", systemImage: "rectangle.stack")
                    }
                    .accessibilityIdentifier("settings.messagePreview")
                    Text("集中预览思考、技能、工具状态与回答内容；样例不会发送请求或执行操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
                #else
                Section {
                    Text("云端模型由 iTalk 账号提供：在 iPhone 的 iTalk 里登录并订阅即可，这里不需要填写任何地址或密钥。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("模型服务") }
                #endif
                Section {
                    grantToggle("云端 AI 处理", .cloudAI)
                    Text("开启后，你主动提交的问答文字会发送到所连接的服务及其模型供应商，按服务公布的费率计费。健康数据另行授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    grantToggle("联网研究", .research)
                    grantToggle("允许健康相关文字发送到云端", .cloudHealth)
                } header: { Text("云端隐私") }
                #if os(iOS)
                Section {
                    NavigationLink { PermissionCenterView() } label: { Label("工具与权限", systemImage: "hand.raised") }.accessibilityIdentifier("settings.permissions")
                } header: { Text("设备端工具") } footer: { Text("健康、日历、提醒、闹钟、位置、联系人、照片、联网等每项能力的开关和 iOS 系统权限都在这里，状态来自系统，不会过期。") }
                #else
                Section {
                    localGrant("健康与睡眠查询", .healthRead)
                    localGrant("日历", .calendar)
                    localGrant("提醒事项", .reminders)
                } header: { Text("设备端工具") }
                #endif
                Section {
                    grantToggle("保存非敏感对话历史", .history)
                    grantToggle("长期记忆", .memory)
                    grantToggle("单独允许保存健康记忆", .healthMemory)
                    grantToggle("本地记忆整理（仅提出候选）", .consolidation)
                    NavigationLink("查看与管理记忆") { MemoryView() }
                    Text("历史最多保留 30 天。健康内容不会写入普通对话历史。记忆需要逐条确认，不会在后台悄悄修改偏好。").font(.caption).foregroundStyle(.secondary)
                } header: { Text("本地记忆") }
                Section("数据控制") {
                    Button("导出本机数据") { do { exportURL = try model.exportData() } catch { model.message = error.localizedDescription } }
                    if let url = exportURL { ShareLink("分享导出文件（包含私人内容）", item: url) }
                    Button("删除本机数据与凭证", role: .destructive) { deleteAll = true }
                    Text("本机删除不会删除 Apple 健康中的原始记录、系统日历或运营方账本。云端账户删除与账单保留政策需要运营方提供。").font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message { Section { Text(message).font(.subheadline).foregroundStyle(.secondary) } }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationDestination(isPresented: $showModelCenter) { ModelCenterView() }
            #endif
            #if DEBUG && os(iOS)
            .navigationDestination(isPresented: $showMessagePreview) { MessagePreviewView() }
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onDisappear {
                if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
                exportURL = nil
            }
            .confirmationDialog("删除本机的历史、记忆、设置及访问凭证？", isPresented: $deleteAll, titleVisibility: .visible) { Button("删除本机数据", role: .destructive) { model.deleteAll() } }
        }
    }
    private func preference(_ path: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.archive.preferences[keyPath: path] }, set: { model.archive.preferences[keyPath: path] = $0; model.persist() })
    }
    private func grantToggle(_ title: String, _ scope: Scope) -> some View {
        Toggle(title, isOn: Binding(get: { model.grants.contains(scope) }, set: { model.setGrant(scope, allowed: $0) }))
    }
    private func localGrant(_ title: String, _ scope: Scope) -> some View {
        Toggle(title, isOn: Binding(get: { model.grants.contains(scope) }, set: { allowed in
            if allowed { Task { await model.authorize(scope) } } else { model.setGrant(scope, allowed: false) }
        }))
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if !model.grants.contains(.history) { Text("对话历史未开启。可在设置中选择是否保存非敏感对话。").foregroundStyle(.secondary) }
                ForEach(model.archive.history.reversed().filter { query.isEmpty || $0.question.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query) }) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.question).font(.headline); Text(entry.answer).font(.body)
                        Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("删除", role: .destructive) { model.archive.history.removeAll { $0.id == entry.id }; model.reviewing = []; model.persist() } }
                }
            }
            .searchable(text: $query, prompt: "搜索本机历史")
            .navigationTitle("对话历史")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var candidate: ConsolidationProposal?
    var body: some View {
        List {
            Section {
                ForEach(model.archive.memories.filter { query.isEmpty || $0.content.localizedCaseInsensitiveContains(query) }) { record in
                    NavigationLink { MemoryEditor(record: record) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.content)
                            Text(record.sensitive ? "敏感 · 独立本地存储范围" : "经你确认 · 本机存储").font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除", role: .destructive) { model.deleteMemory(record.id) } }
                }
                if model.archive.memories.isEmpty { Text("还没有批准保存的记忆。").foregroundStyle(.secondary) }
            }
            Section("整理候选") {
                Button("从已授权历史中整理") { model.reviewMemory() }
                ForEach(model.reviewing) { proposal in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(proposal.content)
                        Button("审阅并保存") { candidate = proposal }
                    }
                }
            }
        }.searchable(text: $query, prompt: "搜索记忆").navigationTitle("记忆")
            .alert("保存这条记忆？", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } })) {
                Button("确认保存") { if let candidate { model.saveReviewedCandidate(candidate) }; candidate = nil }
                Button("取消", role: .cancel) { candidate = nil }
            } message: { Text(candidate?.content ?? "") }
    }
}

private struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: MemoryRecord
    @State private var content = ""
    var body: some View {
        Form {
            Section("内容") {
                #if os(iOS)
                TextEditor(text: $content).frame(minHeight: 120)
                #else
                TextField("记忆内容", text: $content)
                #endif
            }
            Section("来源") {
                LabeledContent("保存时间", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("修订", value: "\(record.revision)")
                Text("来源会话：\(record.sourceTurn.uuidString)").font(.caption)
            }
            if !record.history.isEmpty { Section("修改历史") { ForEach(Array(record.history.enumerated()), id: \.offset) { _, item in Text(item.content).foregroundStyle(.secondary) } } }
            Button("保存修改") { model.editMemory(id: record.id, text: content, revision: record.revision); dismiss() }
        }.navigationTitle("编辑记忆").onAppear { content = record.content }
    }
}

struct ActionReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ActionDraft
    var body: some View {
        NavigationStack {
            Form {
                Section("请核对，确认后才会写入系统") {
                    TextField("标题", text: $draft.title)
                    DatePicker("日期与时间", selection: $draft.date)
                    LabeledContent("时区", value: TimeZone.current.identifier)
                    if draft.kind == .calendar { Text("日程时长：1 小时；不添加邀请人。").font(.caption).foregroundStyle(.secondary) }
                }
                Text("语音中的模糊日期未自动解释，请在这里选择准确时间。").font(.caption).foregroundStyle(.secondary)
                Button("确认保存") { model.saveAction(draft); if model.actionDraft == nil { dismiss() } }.disabled(model.isSaving)
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle(draft.kind == .reminder ? "新建提醒" : "新建日程")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancel(); dismiss() } } }
        }.onDisappear { if model.session.phase == .confirming { model.cancel() } }
    }
}
