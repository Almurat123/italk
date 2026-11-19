import SwiftUI
import AgentRuntime
import RemoteAgent

// CONTEXT MEMORY
// Updated: 2026-10-30
// Status: inferred (simulator verified; device pending)
// Why: The task list showed two lines of summary; the answer, the plan, the steps the agent actually took, approvals and its questions were
//      invisible, and there was no way to start a task from the phone.
// Debug Goal: Start a task, watch what the computer really does (plan, tools, approvals, questions, answer), answer from the phone, come back later.
// Search Tags: remote task view new task composer approval question plan steps transcript follow up
// Invariants:
// - Everything shown is the computer's own event log (RemoteTranscript); nothing is invented by the phone.
// - Approvals and questions are answered here and nowhere else; an expired one is shown as expired.
// - A task keeps running when this screen closes.

struct RemoteTaskView: View {
    let taskId: String
    let deviceId: String
    @Environment(RemoteDeviceCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @State private var followUp = ""
    @State private var answerText = ""
    @State private var failure: String?
    @State private var confirmDelete = false
    @State private var sentGeneratedFollowup = false

    private var info: RemoteTaskInfo? { center.device(deviceId)?.tasks.first { $0.id == taskId } }
    private var transcript: RemoteTranscript { center.transcript(for: taskId) ?? RemoteTranscript() }

    var body: some View {
        List {
            if let info {
                Section { header(info) }
            }
            if !transcript.plan.isEmpty { Section("计划") { ForEach(Array(transcript.plan.enumerated()), id: \.offset) { _, item in planRow(item) } } }
            Section("过程") {
                if transcript.items.isEmpty { HStack { ProgressView().controlSize(.small); Text("等待电脑开始…").foregroundStyle(.secondary) } }
                ForEach(Array(transcript.items.enumerated()), id: \.offset) { _, item in row(item) }
            }
            if let message = failure { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
            if transcript.isFinished { finishedSection }
        }
        .navigationTitle(info?.title ?? "任务").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let info, !info.state.isFinished { Button("停止", role: .destructive) { Task { await center.cancelTask(taskId) } }.accessibilityIdentifier("remote.task.stop") }
                else { Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.accessibilityLabel("删除这个任务") }
            }
        }
        .confirmationDialog("删除后，电脑上这个任务的记录也会被清除。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await center.deleteTask(taskId); dismiss() } }
        }
        .task { await center.openTask(taskId) }
    }

    // MARK: Pieces

    @ViewBuilder private func header(_ info: RemoteTaskInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(info.state)).foregroundStyle(Self.color(info.state))
            Text(Self.stateText(info.state)).font(.subheadline.weight(.semibold))
            Spacer()
            if !info.state.isFinished { ProgressView().controlSize(.small) }
        }
        if info.state == .lost { Text("电脑暂时联系不上，任务可能仍在电脑上运行。联系上之后会显示最新结果。").font(.footnote).foregroundStyle(.secondary) }
        if let model = info.modelId { Text(model.replacingOccurrences(of: "italk/", with: "iTalk · ").replacingOccurrences(of: "ollama/", with: "电脑本地 · ")).font(.caption).foregroundStyle(.secondary) }
    }

    private func planRow(_ item: RemoteTranscript.PlanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dotted.circle" : item.status == "cancelled" ? "xmark.circle" : "circle")
                .foregroundStyle(item.status == "completed" ? Color.green : item.status == "in_progress" ? Color.accentColor : Color.secondary)
            Text(item.text).strikethrough(item.status == "cancelled").foregroundStyle(item.status == "completed" ? .secondary : .primary)
        }.font(.subheadline)
    }

    @ViewBuilder private func row(_ item: RemoteTranscript.Item) -> some View {
        switch item {
        // CONTEXT MEMORY
        // Updated: 2026-11-01
        // Status: inferred
        // Why: Remote task answers previously showed Markdown and code as unformatted text.
        // Debug Goal: Use the chat renderer without routing generated actions into the unrelated local conversation.
        // Search Tags: remote task markdown generated ui wrong conversation
        // Invariants:
        // - Remote text follows its own durable transcript and streaming state.
        // - Remote interface state is isolated by device and task; send/tool actions create a follow-up on that same computer.
        // Failure Modes:
        // - Inheriting the chat handler can send a remote action to a local conversation.
        case .text(let text):
            VStack(alignment: .leading, spacing: 8) {
                MarkdownAnswerView(text: text, streaming: !transcript.isFinished)
                    .environment(\.genUIHandler, GenUIHandler(send: { text, key in
                        await sendGeneratedFollowup(text, key: key)
                    }, canSend: transcript.isFinished && info != nil))
                    .environment(\.genUINamespace, "remote:\(deviceId):\(taskId)")
                if sentGeneratedFollowup && text.localizedCaseInsensitiveContains("```italk-ui") {
                    Text("已发送到电脑，可返回任务列表查看进度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .reasoning(let text): DisclosureGroup("思考过程") { Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }.font(.subheadline)
        case .note(let note): Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        case .step(let id): if let step = transcript.steps[id] { stepRow(step) }
        case .approval(let id): if let approval = transcript.approvals[id] { approvalRow(approval) }
        case .question(let id): if let question = transcript.questions[id] { questionRow(question) }
        }
    }

    private func stepRow(_ step: RemoteTranscript.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch step.state {
            case .running: ProgressView().controlSize(.small).frame(width: 20)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.summary).font(.subheadline)
                if let preview = step.preview, !preview.isEmpty, step.state != .running { Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
    }

    @ViewBuilder private func approvalRow(_ a: RemoteTranscript.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(a.state == .pending ? "需要你确认" : Self.approvalText(a.state), systemImage: a.state == .pending ? "hand.raised.fill" : (a.state == .approved ? "checkmark.shield" : "xmark.shield"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(a.state == .pending ? Color.orange : Color.secondary)
            Text(a.summary).font(.subheadline)
            if a.tainted { Text("这次操作是在读取网页等外部内容之后提出的，请确认确实是你想要的。").font(.caption).foregroundStyle(.orange) }
            if a.state == .pending {
                HStack {
                    Button("允许") { respond(true, rest: false) }.buttonStyle(.borderedProminent).accessibilityIdentifier("remote.approve")
                    if a.scopes.contains("task") && !a.tainted { Button("本任务内都允许") { respond(true, rest: true) }.buttonStyle(.bordered) }
                    Button("不允许", role: .destructive) { respond(false, rest: false) }.buttonStyle(.bordered).accessibilityIdentifier("remote.decline")
                }.controlSize(.small)
            }
        }.padding(.vertical, 2)
    }

    @ViewBuilder private func questionRow(_ q: RemoteTranscript.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(q.state == .pending ? "助手在问你" : "助手的问题", systemImage: "questionmark.bubble.fill").font(.subheadline.weight(.semibold)).foregroundStyle(q.state == .pending ? Color.accentColor : Color.secondary)
            Text(q.text).font(.subheadline)
            switch q.state {
            case .pending:
                ForEach(q.choices, id: \.self) { choice in Button(choice) { answer(choice) }.buttonStyle(.bordered).controlSize(.small) }
                HStack {
                    TextField("或者自己回答", text: $answerText).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote.answer.field")
                    Button("发送") { answer(answerText) }.disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty).buttonStyle(.borderedProminent).controlSize(.small)
                }
            case .answered(let text): Label("你的回答：\(text)", systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary)
            case .unanswered(let reason): Label(reason == "expired" ? "没有及时回答" : "任务已结束", systemImage: "clock").font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }

    @ViewBuilder private var finishedSection: some View {
        switch transcript.phase {
        case .failed(let code, let message):
            Section { Label(message ?? RemoteDeviceCenter.failureText(code), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline) }
        case .cancelled: Section { Label("任务已停止", systemImage: "stop.circle").foregroundStyle(.secondary).font(.subheadline) }
        default: EmptyView()
        }
        Section("继续追问") {
            HStack {
                TextField("接着说…", text: $followUp, axis: .vertical).lineLimit(1...4).accessibilityIdentifier("remote.followup.field")
                Button { sendFollowUp() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送")
            }
        }
    }

    // MARK: Actions

    private func sendGeneratedFollowup(_ text: String, key: String) async -> Bool {
        guard let info, transcript.isFinished else { return false }
        var options = RemoteDeviceCenter.TaskOptions()
        options.continuing = taskId
        options.idempotencyKey = key
        do {
            _ = try await center.submitTask(deviceId: deviceId, prompt: text, modelId: info.modelId, options: options)
            failure = nil; sentGeneratedFollowup = true
            return true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "没能确认发送，请检查网络和任务列表后重试。"
            return false
        }
    }

    private func respond(_ approve: Bool, rest: Bool) {
        Task { do { try await center.respondToApproval(taskId: taskId, approve: approve, forRestOfTask: rest); failure = nil } catch { failure = (error as? LocalizedError)?.errorDescription ?? "没能发送回答，请重试。" } }
    }
    private func answer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { do { try await center.answerQuestion(taskId: taskId, text: trimmed); answerText = ""; failure = nil } catch { failure = (error as? LocalizedError)?.errorDescription ?? "没能发送回答，请重试。" } }
    }
    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let info else { return }
        var options = RemoteDeviceCenter.TaskOptions(); options.continuing = taskId
        Task {
            do { _ = try await center.submitTask(deviceId: deviceId, prompt: text, modelId: info.modelId, options: options); followUp = ""; dismiss() }
            catch { failure = (error as? LocalizedError)?.errorDescription ?? "没能发送，请重试。" }
        }
    }

    // MARK: Vocabulary

    static func stateText(_ s: RemoteTaskState) -> String {
        switch s { case .queued: "排队中"; case .running: "正在执行"; case .awaitingApproval: "等你确认"; case .completed: "已完成"; case .failed: "没有完成"; case .cancelled: "已停止"; case .lost: "联系不上电脑" }
    }
    static func symbol(_ s: RemoteTaskState) -> String {
        switch s { case .queued: "clock"; case .running: "gearshape.2"; case .awaitingApproval: "hand.raised.fill"; case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"; case .cancelled: "stop.circle"; case .lost: "wifi.exclamationmark" }
    }
    static func color(_ s: RemoteTaskState) -> Color {
        switch s { case .completed: .green; case .failed, .lost: .orange; case .awaitingApproval: .orange; case .running, .queued: .accentColor; case .cancelled: .secondary }
    }
    static func approvalText(_ s: RemoteTranscript.Approval.State) -> String {
        switch s { case .pending: "需要你确认"; case .approved: "你已允许"; case .declined: "你没有允许"; case .expired: "确认已过期，没有执行"; case .cancelled: "任务结束，没有执行" }
    }
}

/// Starts a task on a computer: what to do, in which folder, how much it may change on its own, with which of iTalk's models.
struct RemoteNewTaskView: View {
    let deviceId: String
    let started: (String) -> Void
    @Environment(RemoteDeviceCenter.self) private var center
    @Environment(MemoryCenter.self) private var memory
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var folder: String?
    @State private var mode = "ask"
    @State private var model: String?
    @State private var submitting = false
    @State private var failure: String?
    @State private var choosingFolder = false
    @State private var choosingMemory = false
    @State private var sharedMemoryIDs: Set<UUID> = []

    private static let examples = [
        ("看看下载文件夹里最大的文件", "看看我的下载文件夹（~/Downloads）里最大的 10 个文件，列出名称和大小，不要改动任何东西。"),
        ("检查这台 Mac 的状态", "检查一下这台 Mac 现在的健康状况：电池、磁盘空间、内存和最占用 CPU 的程序，用几句话告诉我有没有问题。"),
        ("总结最近改过的文档", "找出我桌面和文稿文件夹里最近一周修改过的文档，各用一句话说它们是什么。"),
    ]

    private var device: RemoteDeviceInfo? { center.device(deviceId) }
    private var ceiling: String { center.statuses[deviceId]?.limits.maxPermissionMode ?? "ask" }
    // CONTEXT MEMORY
    // Updated: 2026-11-02
    // Status: inferred
    // Why: Personal memory must not be shared with a computer automatically.
    // Debug Goal: Send only explicit selections while both memory switches allow access.
    // Search Tags: remote task memory selection sensitive privacy
    // Invariants:
    // - Sensitive or disabled memories are excluded even if they were selected earlier.
    // - The selection starts empty for every new task.
    // Failure Modes:
    // - A stale selection sends a newly sensitive or disabled memory.
    private var shareableMemories: [MemoryItem] { memory.isActive ? memory.items.filter { !$0.sensitive } : [] }
    private var selectedMemories: [MemoryItem] { shareableMemories.filter { sharedMemoryIDs.contains($0.id) } }
    private static let modes = ["readOnly", "ask", "acceptEdits", "auto"]
    private func allowed(_ m: String) -> Bool { (Self.modes.firstIndex(of: m) ?? 0) <= (Self.modes.firstIndex(of: ceiling) ?? 1) }

    var body: some View {
        Form {
            if let device, !device.state.isOnline {
                Section { Label(RemoteStatusText.connection(device.state), systemImage: "wifi.exclamationmark").foregroundStyle(.orange) }
                footer: { Text("电脑联系上之后才能开始任务；已经在电脑上跑的任务不受影响。") }
            }
            Section("想让电脑做什么") {
                TextField("例如：整理下载文件夹里的 PDF", text: $prompt, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("remote.newtask.prompt")
                ForEach(Self.examples, id: \.0) { title, text in Button { prompt = text } label: { Label(title, systemImage: "text.badge.plus").font(.subheadline) } }
            }
            Section {
                Button { choosingFolder = true } label: { LabeledContent("工作文件夹", value: folder.map { ($0 as NSString).lastPathComponent } ?? "不指定") }.foregroundStyle(.primary)
                Picker("权限", selection: $mode) {
                    Text("只读：只看不改").tag("readOnly")
                    Text("逐项确认（推荐）").tag("ask")
                    if allowed("acceptEdits") { Text("自动修改工作文件夹内的文件").tag("acceptEdits") }
                }
                if let models = device?.models, !models.isEmpty {
                    Picker("模型", selection: Binding(get: { model ?? models.first?.id ?? "" }, set: { model = $0 })) { ForEach(models) { Text($0.name + ($0.supportsTools ? "" : " · 仅对话")).tag($0.id) } }
                }
                Button { choosingMemory = true } label: {
                    LabeledContent("本次共享记忆", value: selectedMemories.isEmpty ? "未共享" : "已选择 \(selectedMemories.count) 条")
                }.disabled(shareableMemories.isEmpty)
                if !memory.isActive { Text("记忆已关闭，不能发送给电脑。").font(.caption).foregroundStyle(.secondary) }
                else if shareableMemories.isEmpty { Text("没有可共享的非敏感记忆。").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("设置") } footer: { Text("改动文件或运行命令前，默认会在手机上问你。电脑的主人可以限制最高权限（现在最高：\(Self.modeName(ceiling))）。") }
            if let failure { Section { Text(failure).font(.footnote).foregroundStyle(.orange) } }
            Section {
                Button { submit() } label: { HStack { if submitting { ProgressView().controlSize(.small) }; Text("开始任务").bold() }.frame(maxWidth: .infinity) }
                    .disabled(submitting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || device?.state.isOnline != true).accessibilityIdentifier("remote.newtask.start")
            }
        }
        .navigationTitle("新任务").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingFolder) { NavigationStack { RemoteFolderPicker(deviceId: deviceId, chosen: $folder) } }
        .sheet(isPresented: $choosingMemory) {
            NavigationStack {
                List {
                    Section {
                        ForEach(shareableMemories) { item in
                            Button {
                                if sharedMemoryIDs.contains(item.id) { sharedMemoryIDs.remove(item.id) }
                                else if selectedMemories.count < 10 { sharedMemoryIDs.insert(item.id) }
                            } label: {
                                HStack(alignment: .top) {
                                    Text(item.text).foregroundStyle(.primary)
                                    Spacer()
                                    if sharedMemoryIDs.contains(item.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    } footer: {
                        Text("最多选择 10 条。仅本次任务主动发送到这台电脑；后续对话可能引用本次结果。若选择云端模型，内容还会发送给云端模型服务。电脑可能按任务保留期限保存这些内容。敏感记忆不会在这里显示。")
                    }
                }
                .navigationTitle("选择本次共享的记忆")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosingMemory = false } } }
            }
        }
    }

    private func submit() {
        submitting = true; failure = nil
        var options = RemoteDeviceCenter.TaskOptions(); options.workingFolder = folder; options.permissionMode = allowed(mode) ? mode : "ask"
        options.sharedMemory = selectedMemories.prefix(10).map(\.text)
        let chosen = model ?? device?.models.first?.id
        Task {
            do { let task = try await center.submitTask(deviceId: deviceId, prompt: prompt, modelId: chosen, options: options); started(task.id) }
            catch { failure = (error as? LocalizedError)?.errorDescription ?? "没能开始任务，请重试。" }
            submitting = false
        }
    }

    static func modeName(_ mode: String) -> String {
        switch mode { case "readOnly": "只读"; case "ask": "逐项确认"; case "acceptEdits": "自动修改工作文件夹"; case "auto": "自动"; default: mode }
    }
}

struct RemoteFolderPicker: View {
    let deviceId: String
    @Binding var chosen: String?
    @Environment(RemoteDeviceCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @State private var listing: RemoteFolders?
    @State private var failure: String?

    var body: some View {
        List {
            if let listing {
                Section { Button { chosen = listing.path; dismiss() } label: { Label("使用这个文件夹：\((listing.path as NSString).lastPathComponent)", systemImage: "checkmark.circle") } }
                if let parent = listing.parent { Button { Task { await load(parent) } } label: { Label("上一级", systemImage: "arrow.up") } }
                ForEach(listing.folders, id: \.self) { name in Button { Task { await load((listing.path as NSString).appendingPathComponent(name)) } } label: { Label(name, systemImage: "folder") }.foregroundStyle(.primary) }
            } else if let failure { Text(failure).foregroundStyle(.orange) } else { ProgressView() }
            Section { Button("不指定文件夹") { chosen = nil; dismiss() } }
        }
        .navigationTitle("选择文件夹").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
        .task { await load(chosen ?? "~") }
    }

    private func load(_ path: String) async {
        do { listing = try await center.folders(deviceId: deviceId, path: path); failure = nil }
        catch { failure = (error as? LocalizedError)?.errorDescription ?? "读取不到这台电脑上的文件夹。" }
    }
}
