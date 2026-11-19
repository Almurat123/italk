import SwiftUI
import AssistantCore

/// Read-only gallery for reviewing the chat renderer without calling a model or running tools.
struct MessagePreviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var streamTurn = Self.makeStreamingTurn()
    @State private var streamTask: Task<Void, Never>?

    private let finishedTurn = Self.makeFinishedTurn()
    private let finishedTrace = Self.makeFinishedTrace()
    private let activeTrace = Self.makeActiveTrace()

    // CONTEXT MEMORY
    // Updated: 2026-10-29
    // Status: inferred
    // Why: Designers need to inspect the full chat rendering vocabulary without changing real conversations.
    // Debug Goal: Keep every sample local and prevent preview controls from reaching live tools or services.
    // Search Tags: message style preview sample agent trace settings
    // Invariants:
    // - Sample turns and traces are isolated from the real conversation store.
    // - Approval controls stay disabled and samples never issue model or network requests.
    // Failure Modes:
    // - Reusing live runtime state can turn a visual preview into a real action.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                introduction

                previewSection("对话消息", subtitle: "实际聊天气泡与已完成的思考、执行记录。点按运行摘要可展开或收起。") {
                    ConversationRow(turn: finishedTurn, canRead: false, trace: finishedTrace)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("messagePreview.finishedConversation")
                }

                previewSection("等待与流式输出", subtitle: "模型尚未输出、以及文字逐步到达时的布局。") {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("等待模型").font(.subheadline.weight(.medium))
                            ConversationRow(turn: Self.makeWaitingTurn(), canRead: false)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("流式回答").font(.subheadline.weight(.medium))
                                Spacer()
                                Button { replayStream() } label: {
                                    Label("重播", systemImage: "arrow.clockwise")
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("messagePreview.replayStream")
                            }
                            ConversationRow(turn: streamTurn, canRead: false)
                                .accessibilityIdentifier("messagePreview.streamingConversation")
                            Text("按“重播”可观察内容增长时气泡的排版。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                previewSection("思考与运行中", subtitle: "仅作为界面样例；运行状态不会连接真实模型。") {
                    AgentTraceView(trace: activeTrace, turnId: activeTraceID)
                        .padding(14)
                        .background(.background.secondary.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("messagePreview.activeTrace")
                }

                previewSection("技能状态", subtitle: "展示加载中、已加载与失败后的行内标识。") {
                    VStack(alignment: .leading, spacing: 12) {
                        SkillPreviewRow(title: "加载技能：闹钟与计时", state: .loading)
                        SkillPreviewRow(title: "技能 · 闹钟与计时", state: .loaded)
                        SkillPreviewRow(title: "技能加载失败 · 天气", state: .failed)
                    }
                }

                previewSection("工具与权限状态", subtitle: "展示执行、成功、失败、权限受限和等待确认。样例按钮不可操作。") {
                    VStack(spacing: 10) {
                        ToolPreviewCard(title: "查询天气", detail: "正在读取杭州未来三天的天气", state: .running)
                        ToolPreviewCard(title: "查询日历", detail: "找到 2 项日程", state: .succeeded)
                        ToolPreviewCard(title: "读取位置", detail: "定位权限尚未开启", state: .permission)
                        ToolPreviewCard(title: "发送消息", detail: "发送前需要你的确认", state: .approval)
                        ToolPreviewCard(title: "搜索网页", detail: "网络暂时不可用，可稍后重试", state: .failed)
                    }
                }

                previewSection("回答内容与卡片", subtitle: "常见富文本层级、代码、引用来源和结构化结果。") {
                    VStack(alignment: .leading, spacing: 12) {
                        ConversationRow(turn: Self.makeRichTurn(), canRead: false).accessibilityIdentifier("messagePreview.richAnswer")
                        resultCard
                        sourcePreview
                        attachmentPreview
                    }
                }

                previewSection("结束状态", subtitle: "模型停止、回答失败或内容保留时的提示。") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("已停止", systemImage: "stop.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("回答中断，已保留已生成的文字。", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label("当前模型暂不可用，请切换模型后重试。", systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("消息样式测试")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { streamTask?.cancel(); streamTask = nil }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("本地样例", systemImage: "eye")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            Text("模型消息与状态")
                .font(.title2.weight(.semibold))
            Text("把对话、思考、技能、工具和回答卡片放在一处检查。这里不会访问网络、改变真实会话或执行系统操作。")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markdownPreview: some View {
        PreviewPanel(label: "富文本回答") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text("结论：").bold())周末适合安排户外活动。")
                Text("建议先查看天气，再决定出发时间。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("• 周六：晴到多云，适合步行")
                    Text("• 周日：局部有雨，建议带伞")
                }
                .font(.subheadline)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                    Text("出行前再核对一次实时预报。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.leading, 10)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body)
            .textSelection(.enabled)
        }
    }

    private var codePreview: some View {
        PreviewPanel(label: "代码块") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("swift").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label("复制", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
                Text("let reminder = Reminder(\n    title: \"喝水\",\n    date: .now\n)")
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resultCard: some View {
        PreviewPanel(label: "结构化结果卡片") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.sun.fill").foregroundStyle(.secondary)
                    Text("杭州周末天气").font(.headline)
                    Spacer(minLength: 0)
                    Text("示例数据").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    WeatherDayPreview(day: "周六", temperature: "23°", summary: "晴到多云")
                    WeatherDayPreview(day: "周日", temperature: "20°", summary: "局部有雨")
                }
            }
        }
    }

    private var sourcePreview: some View {
        PreviewPanel(label: "引用与来源") {
            HStack(alignment: .top, spacing: 10) {
                Text("1").font(.caption2.weight(.bold)).frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("天气预报来源").font(.subheadline.weight(.medium))
                    Text("weather.example · 刚刚检索")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var attachmentPreview: some View {
        PreviewPanel(label: "图片输入") {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 68, height: 68)
                    .overlay { Image(systemName: "photo").font(.title3).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("图片附件").font(.subheadline.weight(.medium))
                    Text("用户消息可同时包含文字和图片")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func previewSection<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeTraceID: UUID { UUID(uuidString: "A13BFC2A-30AB-4586-84E5-6A27A57D331C")! }

    private func replayStream() {
        streamTask?.cancel()
        streamTurn = Self.makeStreamingTurn(answer: "")
        let characters = Array(Self.streamingAnswer)
        streamTask = Task { @MainActor in
            for end in stride(from: 4, through: characters.count, by: 4) {
                guard !Task.isCancelled else { return }
                streamTurn.answer = String(characters.prefix(end))
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 75)) }
                catch { return }
            }
            if !Task.isCancelled {
                streamTurn.answer = Self.streamingAnswer
                streamTurn.state = .complete
            }
        }
    }

    private static let streamingAnswer = "我先归纳出三个重点：先确认目标，再处理最重要的一步，最后检查结果是否符合预期。"

    private static func makeFinishedTurn() -> ConversationTurn {
        var turn = ConversationTurn(id: UUID(uuidString: "E054958A-9BA7-4E75-AC4E-4D4D32D24E90")!, question: "杭州周末适合出门吗？")
        turn.answer = "周六晴到多云，周日可能有阵雨。建议周六出行，周日带伞。"
        turn.state = .complete
        return turn
    }

    private static func makeRichTurn() -> ConversationTurn {
        var turn = ConversationTurn(id: UUID(uuidString: "5D0F7C1E-3B5E-4C5A-9F0C-2E7F8B1A9D11")!, question: "用 Swift 写个防抖，并对比两种方案")
        turn.answer = """
        ## 防抖的两种写法

        下面是基于 **Task** 的实现，取消上一次未完成的任务即可：

        ```swift
        final class Debouncer {
            private var task: Task<Void, Never>?
            func call(_ action: @escaping () -> Void) {
                task?.cancel()
                task = Task { try? await Task.sleep(for: .milliseconds(300)); action() }
            }
        }
        ```

        | 方案 | 优点 | 缺点 |
        | --- | --- | --- |
        | Task | 简单 | 需要 async |
        | Timer | 兼容旧系统 | 要手动失效 |

        - 输入框搜索适合 300 ms
        - 按钮防重复点击适合 `1 s`

        $$ f(x) = \\frac{1}{1+e^{-x}} $$

        > 参考：[Swift 并发](https://developer.apple.com/documentation/swift/concurrency)
        """
        turn.state = .complete
        return turn
    }

    private static func makeWaitingTurn() -> ConversationTurn {
        var turn = ConversationTurn(id: UUID(uuidString: "B4E56F3B-A62F-45CA-9219-315F39DD6846")!, question: "帮我总结这段内容。")
        turn.state = .pending
        return turn
    }

    private static func makeStreamingTurn(answer: String = "我先归纳出三个重点：先确认目标，再处理") -> ConversationTurn {
        var turn = ConversationTurn(id: UUID(uuidString: "C2A8527F-D3D7-4E5F-9D38-8F83F7B5A4C1")!, question: "怎样把任务拆得更清楚？")
        turn.answer = answer
        turn.state = .pending
        return turn
    }

    private static func makeFinishedTrace() -> AgentTrace {
        let end = Date.now
        let start = end.addingTimeInterval(-8.4)
        var trace = AgentTrace(startedAt: start)
        trace.items = [
            .reasoning(ReasoningBlock(id: "preview-reasoning", text: "用户在问周末天气，需要先取得实时信息，再给出简短的出行建议。", finished: true)),
            .step(AgentStep(id: "preview-skill", kind: .skill, state: .succeeded,
                            title: "已加载技能：天气与实时天气预报", startedAt: start, finishedAt: end)),
            .step(AgentStep(id: "preview-weather", kind: .tool, state: .succeeded,
                            title: "查询杭州天气", detail: "读取未来两天预报", summary: "已取得周末天气信息",
                            facts: [.init("周六", "23° 晴"), .init("周日", "20° 有雨")], symbol: "cloud.sun",
                            startedAt: start, finishedAt: end))
        ]
        trace.state = .finished
        trace.finishedAt = end
        trace.elapsed = end.timeIntervalSince(start)
        return trace
    }

    private static func makeActiveTrace() -> AgentTrace {
        let start = Date.now.addingTimeInterval(-3.2)
        var trace = AgentTrace(startedAt: start)
        trace.items = [
            .reasoning(ReasoningBlock(id: "preview-live-reasoning", text: "我先检查现有日程，再确认是否有时间冲突。", finished: false)),
            .step(AgentStep(id: "preview-live-skill", kind: .skill, state: .running,
                            title: "加载技能：日历与日程", startedAt: start)),
            .step(AgentStep(id: "preview-live-calendar", kind: .tool, state: .running,
                            title: "正在查询日历", detail: "检查今天的安排", symbol: "calendar", startedAt: start))
        ]
        trace.elapsed = 3.2
        return trace
    }
}

private struct PreviewPanel<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SkillPreviewRow: View {
    enum State: Equatable { case loading, loaded, failed }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 8) {
            if state == .loading {
                ProgressView().controlSize(.mini)
            } else if state == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            }
            Text(title).font(.caption.weight(.medium)).foregroundStyle(state == .failed ? .secondary : .primary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolPreviewCard: View {
    enum State: Equatable { case running, succeeded, permission, approval, failed }
    let title: String
    let detail: String
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                icon.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if state == .approval {
                HStack(spacing: 9) {
                    Button("允许") {}.buttonStyle(.borderedProminent).disabled(true)
                    Button("不允许") {}.buttonStyle(.bordered).disabled(true)
                }
                .controlSize(.small)
            }
            if state == .permission {
                Text("前往系统设置").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .permission: Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .approval: Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct WeatherDayPreview: View {
    let day: String
    let temperature: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(day).font(.caption).foregroundStyle(.secondary)
            Text(temperature).font(.title3.weight(.semibold).monospacedDigit())
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
