import SwiftUI
import AppleSkills
import AgentRuntime

/// One place for what iTalk may do. Each row pairs iTalk's own switch with the real iOS state read live from the system.
/// A tool runs only when BOTH allow it. Functional native layout; Codex owns the visual design.
struct PermissionCenterView: View {
    @State private var platform = AgentPlatform.shared
    @State private var rows: [PermissionRow] = []
    @State private var working: String?
    @State private var note: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text("一项能力要同时满足两点才会工作：iTalk 里的开关是开的，并且 iOS 系统已经允许。系统权限只有你本人能在弹窗或“设置”里更改，iTalk 不会替你更改。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("设备与个人数据") { ForEach(rows.filter { $0.system != .none }) { row($0) } }
            Section("其他能力") { ForEach(rows.filter { $0.system == .none && ![.cloudPersonalData, .cloudHealthData].contains($0.capability) }) { row($0) } }
            Section {
                ForEach(rows.filter { [.cloudPersonalData, .cloudHealthData].contains($0.capability) }) { row($0) }
            } header: { Text("云端模型") } footer: {
                Text("使用云端模型时，日历、联系人、位置、照片等个人数据默认不会交给它；健康数据需要单独允许。本地模型的数据始终留在手机上。")
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(.orange) } }
        }
        .navigationTitle("工具与权限")
        .task { await reload() }
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await reload() } } }   // coming back from Settings
        .refreshable { await reload() }
    }

    private func row(_ r: PermissionRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { r.switchOn }, set: { on in platform.settings.set(r.capability, on); Task { await reload() } })) {
                Label(r.title, systemImage: r.symbol)
            }.accessibilityIdentifier("permission.switch.\(r.capability.rawValue)")
            Text(r.statusText).font(.caption).foregroundStyle(color(r)).fixedSize(horizontal: false, vertical: true)
            switch r.action {
            case .request:
                Button(working == r.id ? "请求中…" : "请求权限") { request(r) }.buttonStyle(.borderedProminent).controlSize(.small).disabled(working != nil)
                    .accessibilityIdentifier("permission.request.\(r.capability.rawValue)")
            case .openSettings:
                Button("前往系统设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("permission.settings.\(r.capability.rawValue)")
            case .enableSwitch, .none: EmptyView()
            }
        }.padding(.vertical, 2)
    }

    private func color(_ r: PermissionRow) -> Color {
        if !r.switchOn { return .secondary }
        switch r.state { case .granted: return .green; case .denied, .restricted: return .orange; default: return .secondary }
    }

    private func request(_ r: PermissionRow) {
        working = r.id; note = nil
        Task {
            let state = await platform.authority.request(r.system)
            if r.system == .health, let e = ApplePermissionAuthority.healthError { note = "健康权限请求没有成功：\(e)" }
            else if state == .notDetermined { note = "系统没有弹出请求。请回到 iTalk 前台后再试。" }
            working = nil
            await reload()
        }
    }

    private func reload() async { rows = await platform.permissionRows() }
}
