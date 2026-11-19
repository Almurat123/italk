import SwiftUI
import AssistantCore
import AgentRuntime
import AlarmKit
import AppleSkills
import UIKit

/// iPhone Settings. One short row per item, grouped by what the person is trying to do.
/// Every value is read from the same stores the rest of the app uses; nothing here keeps its own copy.
struct SettingsHome: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalModelCenter.self) private var center
    @Environment(SkillRegistryCenter.self) private var skillCenter
    @Environment(MemoryCenter.self) private var memoryCenter
    @Environment(AccountCenter.self) private var accountCenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NeuralVoiceCenter.voiceKey) private var voiceId = "moss-yunshu"
    @State private var exportURL: URL?
    @State private var deleteAll = false
    @State private var showModelCenter = false
    @AppStorage(DeveloperMode.key) private var developerFlag = false
    @State private var versionTaps = 0
    @State private var showMessagePreview = ProcessInfo.processInfo.arguments.contains("-messagePreview")
    private var developerMode: Bool { DeveloperMode.enabled || developerFlag }

    private var voiceName: String { NeuralVoiceCenter.displayName(for: voiceId) }
    @Environment(RemoteDeviceCenter.self) private var remote
    /// What is true right now, not a placeholder: nothing paired, how many computers are reachable, or the one that needs attention.
    private var remoteSummary: String {
        guard remote.hasDevices else { return "未添加" }
        if remote.onlineCount == 0 { return "未连接" }
        return remote.devices.contains { $0.state.isOnline && $0.models.isEmpty } ? "需要设置" : "已连接"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CloudServiceView() } label: { accountRow }.accessibilityIdentifier("settings.account")
                }
                Section {
                    NavigationLink { ModelCenterView() } label: { SettingsRow("模型中心", "square.stack.3d.up", value: center.displayName) }
                        .accessibilityIdentifier("settings.modelCenter")
                    NavigationLink { VoiceSettingsView() } label: { SettingsRow("声音", "waveform", value: voiceName) }
                        .accessibilityIdentifier("settings.voice")
                    Toggle(isOn: preference(\.speakResponses)) { SettingsRow("朗读回答", "speaker.wave.2") }
                    Toggle(isOn: preference(\.autoListen)) { SettingsRow("打开后开始听", "ear") }
                } header: { Text("对话") }
                Section {
                    NavigationLink { SkillsHubView() } label: { SettingsRow("技能", "sparkles", value: skillCenter.skills.isEmpty ? nil : "\(skillCenter.enabledCount)/\(skillCenter.skills.count)") }
                        .accessibilityIdentifier("settings.skills")
                    NavigationLink { AllowedActionsView() } label: { SettingsRow("已允许的操作", "checkmark.shield") }
                        .accessibilityIdentifier("settings.allowed")
                    NavigationLink { PermissionCenterView() } label: { SettingsRow("工具与系统权限", "hand.raised") }
                        .accessibilityIdentifier("settings.permissions")
                    NavigationLink { ITalkAlarmsView() } label: { SettingsRow("闹钟与计时", "alarm") }
                        .accessibilityIdentifier("settings.alarms")
                    NavigationLink { RemoteDevicesView() } label: { SettingsRow("我的电脑", "laptopcomputer.and.iphone", value: remoteSummary) }
                        .accessibilityIdentifier("settings.remote")
                } header: { Text("能力") }
                Section {
                    NavigationLink { AppIconSettingsView() } label: { SettingsRow("App 图标", "app.badge") }
                        .accessibilityIdentifier("settings.appIcon")
                    NavigationLink { MemoryManagerView() } label: {
                        SettingsRow("记忆", "brain", value: memoryCenter.isActive ? "\(memoryCenter.items.count) 条" : "已关闭")
                    }
                    NavigationLink { PrivacySettingsView() } label: { SettingsRow("隐私与数据", "lock.shield", value: privacySummary) }
                        .accessibilityIdentifier("settings.privacy")
                } header: { Text("个人") }
                Section {
                    Button { do { exportURL = try model.exportData() } catch { model.message = error.localizedDescription } } label: {
                        SettingsRow("导出本机数据", "square.and.arrow.up")
                    }.foregroundStyle(.primary)
                    if let url = exportURL { ShareLink("分享导出文件（含私人内容）", item: url) }
                    Button(role: .destructive) { deleteAll = true } label: { SettingsRow("删除本机数据", "trash") }
                } header: { Text("数据") } footer: {
                    Text("不会删除 Apple 健康、系统日历里的原始记录。")
                }
                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .contentShape(Rectangle()).onTapGesture { versionTapped() }
                } header: { Text("关于") }
                if developerMode {
                    Section {
                        NavigationLink { DeveloperToolsView() } label: { SettingsRow("开发者工具", "hammer") }
                            .accessibilityIdentifier("settings.developer")
                    } footer: { Text("仅用于界面测试，不属于正常功能。") }
                }
                if let message = model.message { Section { Text(message).font(.subheadline).foregroundStyle(.secondary) } }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showMessagePreview) { DeveloperToolsView() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onDisappear { if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil }
            .confirmationDialog("删除本机的历史、记忆、设置及访问凭证？", isPresented: $deleteAll, titleVisibility: .visible) {
                Button("删除本机数据", role: .destructive) { model.deleteAll() }
            }
        }
    }

    private var accountRow: some View {
        HStack(spacing: 14) {
            BrandAvatar(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("我的 iTalk").font(.headline)
                Text(CloudServiceView.statusText(accountCenter.availability))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private var privacySummary: String {
        let on = [Scope.cloudAI, .research, .history].filter { model.grants.contains($0) }.count
        return on == 0 ? "仅本机" : "\(on) 项云端"
    }

    private func versionTapped() {
        versionTaps += 1
        if versionTaps >= 7 { versionTaps = 0; developerFlag.toggle() }
    }

    private func preference(_ path: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.archive.preferences[keyPath: path] }, set: { model.archive.preferences[keyPath: path] = $0; model.persist() })
    }
}

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: People can choose either companion icon without changing the animated character.
// Debug Goal: Reflect the icon actually selected by iOS and surface any system error.
// Search Tags: settings alternate app icon companion square circle
// Invariants:
// - The app uses only alternate icon names packaged into its asset catalog.
// - The checkmark follows UIApplication's real state, not a separate preference.
// Failure Modes:
// - A saved preference can claim success when iOS rejected the icon change.
private struct AppIconSettingsView: View {
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                choice("方圆精灵", image: "OrbIconDefault", iconName: nil)
                choice("圆形精灵", image: "OrbIconCircle", iconName: "OrbCircle")
            } footer: {
                Text("切换 iPhone 主屏幕上的 iTalk 图标，不会改变对话里的精灵球。")
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
            if !UIApplication.shared.supportsAlternateIcons {
                Section { Text("当前设备暂不支持切换 App 图标。") }
            }
        }
        .navigationTitle("App 图标").navigationBarTitleDisplayMode(.inline)
        .onAppear { currentIcon = UIApplication.shared.alternateIconName }
    }

    private func choice(_ title: String, image: String, iconName: String?) -> some View {
        Button {
            guard currentIcon != iconName, !changing else { return }
            changing = true; errorMessage = nil
            UIApplication.shared.setAlternateIconName(iconName) { error in
                Task { @MainActor in
                    currentIcon = UIApplication.shared.alternateIconName
                    errorMessage = error.map { "无法切换图标：\($0.localizedDescription)" }
                    changing = false
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(image).resizable().scaledToFit().frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(title).foregroundStyle(.primary)
                Spacer()
                if currentIcon == iconName { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .disabled(changing || !UIApplication.shared.supportsAlternateIcons)
        .accessibilityIdentifier("settings.appIcon.\(iconName ?? "default")")
    }
}

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: AlarmKit exposes alarms belonging to this app independently of the Clock app's alarm list.
// Debug Goal: Show and cancel real system-reported iTalk alarms without inventing missing labels.
// Search Tags: italk alarmkit list clock app alarms timers manage
// Invariants:
// - Permission denial and read errors remain visible instead of appearing as an empty list.
// - Cancel only a system-reported alarm after explicit confirmation.
// Failure Modes:
// - AlarmKit Alarm does not expose the original title; only display titles recorded when the tool created them.
private struct ITalkAlarmsView: View {
    @State private var alarms: [Alarm] = []
    @State private var error: String?
    @State private var pending: Alarm?
    @State private var authorization = AlarmManager.shared.authorizationState

    var body: some View {
        List {
            Section {
                if authorization == .denied {
                    Text("闹钟权限已关闭。请在系统设置中允许 iTalk 使用闹钟。")
                } else if authorization == .notDetermined {
                    Button("允许闹钟与计时") { Task { await requestAccess() } }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { refresh() }
                } else if alarms.isEmpty {
                    Text("没有 iTalk 创建的闹钟或计时。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alarms) { alarm in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let label = ITalkAlarmLabels.label(for: alarm.id), !label.isEmpty {
                                    Text(label).font(.headline)
                                }
                                Text(description(alarm)).font(.body)
                                Text(stateDescription(alarm.state)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("取消", role: .destructive) { pending = alarm }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            } footer: {
                Text("这里只显示 iTalk 创建的闹钟和计时，它们不会出现在 Apple 时钟 App 的列表中。较早创建的项目可能不显示名称。")
            }
        }
        .navigationTitle("闹钟与计时").navigationBarTitleDisplayMode(.inline)
        .task {
            refresh()
            for await _ in AlarmManager.shared.alarmUpdates { refresh() }
        }
        .confirmationDialog("取消这条闹钟或计时？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("取消闹钟或计时", role: .destructive) {
                guard let alarm = pending else { return }
                do { try AlarmManager.shared.cancel(id: alarm.id); ITalkAlarmLabels.remove(for: alarm.id); pending = nil; refresh() }
                catch { self.error = "无法取消：\(error.localizedDescription)"; pending = nil }
            }
        }
    }

    private func refresh() {
        authorization = AlarmManager.shared.authorizationState
        guard authorization == .authorized else { alarms = []; error = nil; return }
        do { alarms = try AlarmManager.shared.alarms; error = nil }
        catch { self.error = "无法读取闹钟：\(error.localizedDescription)" }
    }
    private func requestAccess() async {
        do { authorization = try await AlarmManager.shared.requestAuthorization(); refresh() }
        catch { self.error = "无法请求权限：\(error.localizedDescription)" }
    }
    private func description(_ alarm: Alarm) -> String {
        switch alarm.schedule {
        case .fixed(let date): return "闹钟 · " + date.formatted(date: .abbreviated, time: .shortened)
        case .relative(let relative): return String(format: "闹钟 · %02d:%02d", relative.time.hour, relative.time.minute)
        case nil: return "计时"
        @unknown default: return "闹钟或计时"
        }
    }
    private func stateDescription(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: "已安排"
        case .countdown: "计时中"
        case .paused: "已暂停"
        case .alerting: "正在响铃"
        @unknown default: "状态未知"
        }
    }
}

/// Icon + short title (+ trailing current value). The only row shape Settings uses.
struct SettingsRow: View {
    let title: String, symbol: String, value: String?
    init(_ title: String, _ symbol: String, value: String? = nil) { self.title = title; self.symbol = symbol; self.value = value }
    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            if let value { Spacer(minLength: 8); Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// iTalk's own switches. iOS system permissions live under 工具与系统权限.
struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                grant("云端 AI 处理", "cloud", .cloudAI, info: "开启后，你发送的文字会交给云端模型处理。关闭时只使用本机模型。")
                grant("联网研究", "globe", .research, info: "需要查资料时访问网页。")
                grant("健康文字上传云端", "heart.text.square", .cloudHealth, info: "默认关闭。健康数据另行授权，且只在你开启时才会发给云端模型。")
            } header: { Text("云端") }
            Section {
                grant("保存对话历史", "clock.arrow.circlepath", .history, info: "仅保存非敏感对话，最多 30 天。")
                grant("长期记忆", "brain", .memory, info: "每条记忆都需要你确认。")
                grant("健康记忆", "heart", .healthMemory, info: "单独授权才会保存健康相关记忆。")
                grant("本地记忆整理", "wand.and.sparkles", .consolidation, info: "只提出候选，不会自动修改。")
            } header: { Text("本机") } footer: {
                Text("这里是 iTalk 自己的开关。iOS 系统权限（健康、日历、位置等）请在“工具与系统权限”中查看。")
            }
        }.navigationTitle("隐私与数据").navigationBarTitleDisplayMode(.inline)
    }
    private func grant(_ title: String, _ symbol: String, _ scope: Scope, info: String) -> some View {
        InfoToggle(title: title, symbol: symbol, info: info,
                   isOn: Binding(get: { model.grants.contains(scope) }, set: { model.setGrant(scope, allowed: $0) }))
    }
}

/// A one-line toggle whose explanation sits behind an info button instead of a paragraph under the row.
struct InfoToggle: View {
    let title: String, symbol: String, info: String
    @Binding var isOn: Bool
    @State private var showing = false
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                Button { showing = true } label: { Image(systemName: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("\(title)说明")
                    .popover(isPresented: $showing) { Text(info).font(.subheadline).padding().frame(width: 260).presentationCompactAdaptation(.popover) }
            }
        }
    }
}
