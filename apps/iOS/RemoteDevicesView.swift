import SwiftUI
import AVFoundation
import AgentRuntime
import RemoteAgent

/// The person's own computers. Everything shown is what the computer or the iTalk service reported; nothing is a placeholder. With no computer yet the
/// page is the setup guide (install, scan, account, first task); with one, it is status, model access, what it can do, and its tasks.
struct RemoteDevicesView: View {
    @Environment(RemoteDeviceCenter.self) private var center
    @State private var scanning = false

    var body: some View {
        List {
            pairingSection
            if !center.isSupported {
                Section { ContentUnavailableView { Label("暂未开放", systemImage: "laptopcomputer.slash") } description: { Text(center.unsupportedReason) } }
            } else if center.devices.isEmpty {
                Section { RemoteSetupGuide(hasComputer: false, scan: { scanning = true }, paste: pair) }
            }
            if !center.devices.isEmpty {
                Section {
                    ForEach(center.devices) { device in
                        NavigationLink { RemoteDeviceDetailView(id: device.id) } label: { row(device) }.accessibilityIdentifier("remote.device.\(device.name)")
                    }
                } header: { Text("我的电脑") }
            }
            if !center.devices.isEmpty {
                Section { NavigationLink { List { Section { RemoteSetupGuide(hasComputer: true, scan: { scanning = true }, paste: pair) } }.navigationTitle("设置指南").navigationBarTitleDisplayMode(.inline) } label: { Label("添加另一台电脑 / 设置指南", systemImage: "plus.circle") } }
            }
        }
        .navigationTitle("我的电脑").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .disabled(!center.isSupported).accessibilityLabel("扫码添加电脑").accessibilityIdentifier("remote.scan")
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerView { payload in scanning = false; Task { await center.beginPairing(payload: payload) } } cancel: { scanning = false }
        }
        .task { await center.refresh() }
        .refreshable { await center.refresh() }
    }

    private func pair(_ link: String) { Task { await center.beginPairing(payload: link.trimmingCharacters(in: .whitespacesAndNewlines)) } }

    @ViewBuilder private var pairingSection: some View {
        switch center.pairing {
        case .failed(let failure): Section { Label(failure.message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
        case .awaitingApprovalOnComputer(let fp):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("请在 Mac 上确认", systemImage: "desktopcomputer").font(.headline)
                    Text("Mac 的终端里应该显示同样的代码；一致就按 y，不一致就按 n。").font(.subheadline).foregroundStyle(.secondary)
                    Text(fp).font(.title2.monospaced().weight(.semibold)).accessibilityIdentifier("remote.pairing.code")
                }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            }
        case .connecting: Section { HStack { ProgressView().controlSize(.small); Text("正在连接电脑…").font(.subheadline) } }
        default: EmptyView()
        }
    }

    private func row(_ device: RemoteDeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(device.os)).font(.title3).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(RemoteStatusText.connection(device.state)).font(.footnote).foregroundStyle(RemoteStatusText.color(device.state))
                if device.state.isOnline, let hint = accessHint(device) { Text(hint).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if !device.tasks.filter({ !$0.state.isFinished }).isEmpty { ProgressView().controlSize(.small) }
        }
    }

    private func accessHint(_ device: RemoteDeviceInfo) -> String? {
        switch center.access[device.id] ?? .unknown {
        case .ready, .unknown: nil
        case .notConfigured: device.models.isEmpty ? "还需要设置模型访问" : "电脑本地模型可用 · 云端未设置"
        case .providing: "正在设置模型访问…"
        case .problem(_, let message): message
        }
    }

    static func symbol(_ os: RemoteOS) -> String {
        switch os { case .mac: "laptopcomputer"; case .windows: "pc"; case .linux: "terminal"; case .other: "desktopcomputer" }
    }
    static func osName(_ os: RemoteOS) -> String {
        switch os { case .mac: "macOS"; case .windows: "Windows"; case .linux: "Linux"; case .other: "电脑" }
    }
    static func stateText(_ state: RemoteConnectionState) -> String { RemoteStatusText.connection(state) }
}

struct RemoteDeviceDetailView: View {
    let id: String
    @Environment(RemoteDeviceCenter.self) private var center
    @Environment(AccountCenter.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var path: String?

    var body: some View {
        if let device = center.device(id) {
            List {
                statusSection(device)
                accessSection(device)
                workSection(device)
                if !device.tasks.isEmpty {
                    Section("任务") {
                        ForEach(device.tasks) { task in
                            NavigationLink { RemoteTaskView(taskId: task.id, deviceId: id) } label: { taskRow(task) }
                        }
                    }
                }
                Section { Button("移除这台电脑", role: .destructive) { confirmRemove = true } } footer: { Text("移除后需要重新扫码配对；这台电脑给手机的访问权限也会被清除。") }
            }
            .navigationTitle(device.name).navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $path) { taskId in RemoteTaskView(taskId: taskId, deviceId: id) }
            .confirmationDialog("移除后需要重新扫码配对。", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("移除", role: .destructive) { Task { await center.revoke(device.id); dismiss() } }
            }
            .task { await center.refresh(); await center.loadCapabilities(deviceId: id) }
            .refreshable { await center.refresh() }
        } else { ContentUnavailableView("这台电脑已移除", systemImage: "laptopcomputer.slash") }
    }

    // MARK: Sections

    private func statusSection(_ device: RemoteDeviceInfo) -> some View {
        Section("连接") {
            LabeledContent("状态") { Text(RemoteStatusText.connection(device.state)).foregroundStyle(RemoteStatusText.color(device.state)) }
            if let seen = device.lastSeen { LabeledContent("最后在线") { Text(seen, style: .relative) } }
            LabeledContent("系统", value: RemoteDevicesView.osName(device.os))
            if let v = device.agentVersion { LabeledContent("智能体版本", value: v) }
            LabeledContent("配对代码", value: device.fingerprint).font(.footnote.monospaced())
            if !device.state.isOnline { Button("重新连接", systemImage: "arrow.clockwise") { Task { await center.reconnect(device.id) } }.accessibilityIdentifier("remote.reconnect") }
            if case .unreachable = device.state { Text("请确认这台 Mac 已开机、没有休眠，并且和手机在同一网络。任务运行期间 Mac 会自动保持唤醒；任务不会因为手机断开而停止。").font(.footnote).foregroundStyle(.secondary) }
            if case .revoked = device.state { Text("这台电脑已经取消了这部手机的授权，请移除后重新扫码配对。").font(.footnote).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private func accessSection(_ device: RemoteDeviceInfo) -> some View {
        let state = center.access[id] ?? .unknown
        Section {
            switch state {
            case .unknown: HStack { ProgressView().controlSize(.small); Text("正在检查…").foregroundStyle(.secondary) }
            case .providing: HStack { ProgressView().controlSize(.small); Text("正在把 iTalk 模型访问交给这台电脑…") }
            case .notConfigured:
                Label("这台电脑还不能使用 iTalk 模型", systemImage: "key.slash").foregroundStyle(.orange)
                setupButton("为这台电脑设置 iTalk 模型")
            case .ready(let models, let plan):
                Label("已就绪" + (plan.map { " · \($0)" } ?? ""), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                ForEach(models) { m in LabeledContent(m.name ?? m.id, value: m.contextTokens.map { "\($0 / 1000)K 上下文" } ?? "") }
                Button("重新检查", systemImage: "arrow.clockwise") { Task { await center.verifyAccess(deviceId: id) } }.font(.footnote)
            case .problem(let code, let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                switch code {
                case "signed_out": NavigationLink { CloudServiceView() } label: { Label("登录 iTalk 账号", systemImage: "person.crop.circle") }
                case "subscription_required": NavigationLink { CloudServiceView() } label: { Label("查看订阅", systemImage: "creditcard") }
                default: setupButton("重新设置")
                }
            }
        } header: { Text("iTalk 模型") } footer: { Text("电脑通过你的 iTalk 账号使用云端模型，用量计入你的订阅；电脑上不保存任何其他服务的密钥，也不需要下载模型。") }
    }

    private func setupButton(_ title: String) -> some View {
        Button { Task { await center.provisionAccess(deviceId: id) } } label: { Label(title, systemImage: "arrow.triangle.2.circlepath") }.accessibilityIdentifier("remote.provision")
    }

    @ViewBuilder private func workSection(_ device: RemoteDeviceInfo) -> some View {
        Section("让它做事") {
            if !device.models.isEmpty && device.state.isOnline {
                NavigationLink { RemoteNewTaskView(deviceId: id) { taskId in path = taskId } } label: { Label("新任务", systemImage: "plus.bubble") }.accessibilityIdentifier("remote.newtask")
            } else {
                Label(device.state.isOnline ? "设置 iTalk 云端模型，或在电脑运行 Ollama 本地模型" : "电脑在线并设置好模型后才能开始任务", systemImage: "lock").foregroundStyle(.secondary).font(.subheadline)
            }
            if let caps = center.capabilities[id] {
                NavigationLink { RemoteCapabilitiesView(caps: caps) } label: { LabeledContent("它能做什么", value: "\(caps.tools.count) 个工具 · \(caps.skills.count) 个技能") }
            }
        }
    }

    private func taskRow(_ task: RemoteTaskInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: RemoteTaskView.symbol(task.state)).foregroundStyle(RemoteTaskView.color(task.state))
                Text(task.title).lineLimit(1)
                Spacer()
                Text(RemoteTaskView.stateText(task.state)).font(.caption).foregroundStyle(.secondary)
            }
            if !task.summary.isEmpty { Text(task.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

/// Which tools and skills the computer has, and what each can change. Read from the computer, not assumed.
struct RemoteCapabilitiesView: View {
    let caps: AgentCapabilities
    var body: some View {
        List {
            Section("工具") {
                ForEach(caps.tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(tool.name).font(.subheadline.monospaced()); Spacer(); Text(Self.risk(tool.risk)).font(.caption).foregroundStyle(tool.risk == "read" ? Color.secondary : Color.orange) }
                        Text(tool.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if caps.skills.isEmpty { Text("没有技能。").foregroundStyle(.secondary) }
                ForEach(caps.skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(skill.name).font(.subheadline.weight(.medium)); Spacer(); Text(Self.source(skill.source)).font(.caption).foregroundStyle(.secondary) }
                        Text(skill.description).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("技能") } footer: { Text("技能是写好的做事步骤，只在任务需要时才读取。你可以在电脑上的“iTalk Agent/skills”文件夹或项目的 .italk/skills 里放自己的。") }
            if let instructions = caps.instructions {
                Section("项目说明") { Label("\(instructions.file)（\(instructions.chars) 字）\(instructions.blocked ? " · 因内容不安全未加载" : "")", systemImage: "doc.text") }
            }
        }
        .navigationTitle("它能做什么").navigationBarTitleDisplayMode(.inline)
    }
    static func risk(_ r: String) -> String { switch r { case "read": "只读"; case "modify": "会修改"; case "external": "联网/打开"; default: "敏感" } }
    static func source(_ s: String) -> String { switch s { case "bundled": "内置"; case "user": "我的"; case "workspace": "项目"; default: s } }
}

/// Camera QR reader. Returns the raw payload; validation belongs to the pairing protocol.
struct QRScannerView: View {
    let found: (String) -> Void
    let cancel: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRCamera(found: found).ignoresSafeArea()
            Button("取消", action: cancel).buttonStyle(.glass).padding()
        }
    }
}

private struct QRCamera: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(found: found) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession(); let found: (String) -> Void; private var done = false
        init(found: @escaping (String) -> Void) { self.found = found; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
            view.layer.addSublayer(layer)
            DispatchQueue.global().async { [session] in session.startRunning() }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); view.layer.sublayers?.first?.frame = view.bounds }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true; found(text)
        }
    }
}
