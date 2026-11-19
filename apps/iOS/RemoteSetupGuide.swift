import SwiftUI
import AgentRuntime
import RemoteAgent

// CONTEXT MEMORY
// Updated: 2026-10-30
// Status: inferred (simulator verified; device pending)
// Why: "我的电脑" showed a connected device with nothing to do next: no way to install the Mac side, no sign that the computer could think, no
//      first task. The owner's rule: users choose iTalk's models, connect their Mac and let the agent work; no local model, no API key.
// Debug Goal: A new person can go from nothing to a finished task on their Mac without leaving this page, and sees exactly which step is
//      waiting when something is not ready.
// Search Tags: remote computer setup install mac agent pairing model access first task guide
// Invariants:
// - The only thing a Mac needs is the iTalk agent; model access comes from the person's own iTalk account through the paired phone.
// - Every status shown is read from RemoteDeviceCenter / AccountCenter; nothing here is a placeholder.
// - The install command is derived from the gateway address baked into the build; nobody types a hostname.
// Failure Modes:
// - Showing "ready" while the computer has no credential or the plan ended.

/// Plain-language status for a connection, shared by the list and the detail page.
enum RemoteStatusText {
    static func connection(_ state: RemoteConnectionState) -> String {
        switch state {
        case .disconnected: "未连接"
        case .connecting: "正在连接…"
        case .authenticating: "正在验证…"
        case .connected: "已连接"
        case .reconnecting(let n): "正在重连（第 \(n) 次）"
        case .unreachable(let since): "找不到这台电脑（\(away(since))）"
        case .revoked: "这台电脑已取消了对此手机的授权"
        case .failed(let why): "连接失败：\(why)"
        }
    }
    /// How long the computer has been out of reach, in the words a person would use.
    private static func away(_ since: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        if seconds < 60 { return "刚刚断开" }
        if seconds < 3600 { return "已 \(seconds / 60) 分钟" }
        return "已 \(seconds / 3600) 小时"
    }
    static func color(_ state: RemoteConnectionState) -> Color {
        switch state { case .connected: .green; case .reconnecting, .connecting, .authenticating: .orange; case .unreachable, .revoked, .failed: .red; case .disconnected: .secondary }
    }
}

struct RemoteSetupGuide: View {
    @Environment(AccountCenter.self) private var account
    let hasComputer: Bool
    let scan: () -> Void
    /// The pairing link pasted from the clipboard (copy it on the Mac: Universal Clipboard, or Messages/AirDrop to this phone).
    let paste: (String) -> Void
    @State private var copied = false

    private var installCommand: String? { CloudEndpoint.url.map { "curl -fsSL \($0.absoluteString)/mac/install.sh | sh" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("让你的 Mac 替你干活").font(.title3.weight(.semibold))
                Text("文件、命令、网页和技能都在你的 Mac 上执行。你可以使用电脑上的 Ollama 本地模型，也可以登录 iTalk 使用云端模型。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            step(1, done: hasComputer, title: "在 Mac 上安装 iTalk 智能体") {
                Text("在 Mac 上打开“终端”，粘贴这一行并回车。它会安装并在后台启动，然后显示二维码。")
                if let command = installCommand {
                    HStack(alignment: .top, spacing: 8) {
                        Text(command).font(.footnote.monospaced()).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        Button { UIPasteboard.general.string = command; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("复制安装命令").accessibilityIdentifier("remote.copyInstall")
                    }
                    .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    ShareLink(item: command) { Label("发给 Mac（隔空投送或信息）", systemImage: "square.and.arrow.up").font(.footnote) }
                } else {
                    Label("这个版本还没有配置 iTalk 云端地址，暂时无法生成安装命令。", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Text("需要 macOS 13 以上、能上网；安装包很小，已有 Node 22 就直接使用，没有会自动下载官方版本。").font(.caption).foregroundStyle(.secondary)
            }
            step(2, done: hasComputer, title: "扫码，并在 Mac 上确认") {
                Text("终端里的二维码用下面的按钮扫描。手机上显示的 12 位代码要和 Mac 上显示的一致，在 Mac 上按 y 确认。")
                HStack(spacing: 12) {
                    Button { scan() } label: { Label("扫码添加电脑", systemImage: "qrcode.viewfinder") }.buttonStyle(.borderedProminent).accessibilityIdentifier("remote.scanInline")
                    PasteButton(payloadType: String.self) { strings in if let link = strings.first { paste(link) } }.labelStyle(.titleOnly).accessibilityIdentifier("remote.pasteLink")
                }
                Text("扫不了码？在 Mac 上复制终端里的“italk-pair://…”链接，再回到这里点“粘贴”。").font(.caption)
            }
            step(3, done: account.canUseCloudModels, title: "选择模型来源") {
                Text("使用电脑本地模型：在 Mac 上运行 Ollama 并安装模型，无需 iTalk 云端账号。支持工具的模型可以执行电脑任务。")
                Text("使用 iTalk 云端模型：登录并订阅后，手机会为电脑设置云端访问。")
                accountStatus
            }
            step(4, done: false, title: "试一个真实任务") {
                Text("配对完成后，点开这台电脑，选一个示例任务（比如“看看下载文件夹里最大的文件”），它会在你的 Mac 上真的执行，需要改动时会先问你。")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var accountStatus: some View {
        switch account.availability {
        case .available:
            Label("已登录并订阅，Mac 可以使用 iTalk 模型。", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .needsSignIn:
            Text("如需使用 iTalk 云端模型，请先登录；本地模型不需要登录。")
            NavigationLink { CloudServiceView() } label: { Label("登录 iTalk 账号", systemImage: "person.crop.circle") }
        case .needsSubscription:
            Text("已登录，但还没有有效的订阅；订阅后 Mac 才能使用 iTalk 云端模型。")
            NavigationLink { CloudServiceView() } label: { Label("查看订阅", systemImage: "creditcard") }
        case .offline:
            Label("手机现在联不上 iTalk 云端。", systemImage: "wifi.slash").font(.footnote).foregroundStyle(.orange)
        case .notDeployed:
            Label("iTalk 云端服务还没有开通。", systemImage: "cloud.slash").font(.footnote).foregroundStyle(.orange)
        case .serviceError(let why):
            Label(why, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        }
    }

    private func step<Content: View>(_ number: Int, done: Bool, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.18)).frame(width: 28, height: 28)
                if done { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white) } else { Text("\(number)").font(.footnote.bold()).foregroundStyle(Color.accentColor) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content().font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
