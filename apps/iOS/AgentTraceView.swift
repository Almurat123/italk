import SwiftUI
import AssistantCore
import AgentRuntime

// One compact component system for everything the agent does in a turn, modelled on Codex desktop: a single disclosure line
// ("思考与执行 · 9秒"), and inside it a hairline timeline of reasoning (same body type as the answer, dimmed), tool and skill
// rows, approval / permission cards and structured results. Every state shown comes from the real trace; nothing is invented.

/// Live activity and real reasoning for a turn, collapsed to one line after completion.
struct AgentTraceView: View {
    let trace: AgentTrace
    let turnId: UUID
    /// nil = automatic: open while working or while something needs the person, closed otherwise.
    @State private var userChoice: Bool? = Self.startsOpen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    private static let startsOpen: Bool? = ProcessInfo.processInfo.arguments.contains("-pgExpand") ? true : nil   // scripted screenshots
    #else
    private static let startsOpen: Bool? = nil
    #endif

    private var needsAttention: Bool {
        trace.steps.contains { $0.state == .awaitingApproval || $0.state == .needsPermission }
            && (trace.isActive || Date.now.timeIntervalSince(trace.finishedAt ?? .now) < 600)
    }
    private var isOpen: Bool { userChoice ?? (trace.isActive || needsAttention) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                TraceTimeline(items: visibleItems, live: trace.isActive)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: isOpen)
        .accessibilityElement(children: .contain).accessibilityIdentifier("agent.trace")
    }

    /// While running, only the newest reasoning draft is shown so earlier drafts do not stack up between tool calls.
    private var visibleItems: [AgentTrace.Item] {
        guard trace.isActive else { return trace.items }
        let lastReasoning = trace.reasoning.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.id
        return trace.items.filter { item in
            if case .reasoning(let block) = item { return block.id == lastReasoning }
            return true
        }
    }

    private var header: some View {
        Button { userChoice = !isOpen } label: {
            HStack(spacing: 6) {
                if trace.isActive {
                    ShimmerText(text: liveLabel)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TraceDuration.text(max(trace.elapsed, context.date.timeIntervalSince(trace.startedAt))))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(finishedLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(trace.isActive ? liveLabel : finishedLabel).accessibilityHint(isOpen ? "收起" : "展开")
        .accessibilityIdentifier("agent.trace.header")
    }

    private var finishedLabel: String {
        trace.summaryTitle + (trace.state == .paused ? " · 已暂停" : trace.state == .cancelled ? " · 已停止" : trace.state == .failed ? " · 未完成" : "")
    }

    /// What is happening right now, in words that match the latest real event.
    private var liveLabel: String {
        if let step = trace.steps.last(where: { $0.state == .running || $0.state == .awaitingApproval }) {
            return step.state == .awaitingApproval ? "等待你确认" : step.title
        }
        if trace.steps.contains(where: { $0.state == .needsPermission }) { return "需要你处理权限" }
        if let last = trace.items.last, case .reasoning(let r) = last, !r.finished { return "思考中" }
        return "处理中"
    }
}

/// The expanded history: one hairline rail, one glyph column, one content column for every item kind.
struct TraceTimeline: View {
    let items: [AgentTrace.Item]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                switch item {
                case .reasoning(let block):
                    TraceRow(glyph: { Circle().fill(Color(uiColor: .tertiaryLabel)).frame(width: 5, height: 5).padding(.top, 9) }) {
                        ReasoningBlockView(block: block, live: live && !block.finished)
                    }
                case .step(let step):
                    AgentStepRow(step: step)
                }
            }
        }
        .background(alignment: .leading) {
            Rectangle().fill(MarkdownStyle.hairline).frame(width: 0.5).padding(.vertical, 8).padding(.leading, 8.75)
        }
    }
}

/// Shared row geometry for the timeline: an 18 pt glyph column on the rail, then the content.
struct TraceRow<Glyph: View, Content: View>: View {
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph.frame(width: 18, alignment: .center)
                .background(Color(uiColor: .systemBackground).padding(.vertical, -2))
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The model's own reasoning: the same body font, size and line spacing as the answer, only dimmed.
struct ReasoningBlockView: View {
    let block: ReasoningBlock
    let live: Bool

    var body: some View {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            MarkdownAnswerView(text: text, secondary: true, streaming: live, renderGeneratedUI: false)
                .accessibilityElement(children: .combine).accessibilityLabel("思考：\(text)")
                .accessibilityIdentifier("agent.reasoning")
        }
    }
}

/// One tool, skill, web, approval or permission step.
struct AgentStepRow: View {
    let step: AgentStep
    @State private var platform = AgentPlatform.shared
    @State private var failure: String?
    @State private var busy = false
    @State private var expanded: Bool?
    @Environment(\.openURL) private var openURL
    @Environment(\.simulation) private var simulation

    private var hasDetails: Bool { !step.summary.isEmpty || !step.facts.isEmpty || !step.sources.isEmpty }
    private var isOpen: Bool { expanded ?? (step.state == .failed || !step.facts.isEmpty) }

    var body: some View {
        Group {
            if step.state == .awaitingApproval || step.state == .needsPermission {
                TraceRow(glyph: { glyph.padding(.top, 12) }) { ActionCard(step: step, tint: step.state == .awaitingApproval ? .accentColor : .orange) { actions } }
            } else {
                TraceRow(glyph: { glyph.frame(height: 22) }) {
                    VStack(alignment: .leading, spacing: 8) {
                        titleLine
                        if isOpen && hasDetails { details }
                        if step.recovery != .none, step.state != .succeeded { actions }
                        if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("agent.step.\(step.id)")
    }

    private var titleLine: some View {
        Button { if hasDetails { withAnimation(.smooth(duration: 0.25)) { expanded = !isOpen } } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(step.state == .declined || step.state == .cancelled ? .secondary : .primary)
                    .lineLimit(2)
                if !step.detail.isEmpty {
                    Text(step.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let duration { Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                if hasDetails {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .frame(minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!hasDetails)
    }

    private var title: String {
        switch step.kind {
        case .skill:
            return step.title.replacingOccurrences(of: "已加载技能：", with: "使用技能 · ").replacingOccurrences(of: "查看技能：", with: "查看技能 · ")
        default:
            switch step.state {
            case .declined: return "已拒绝 · " + step.title
            case .cancelled: return "已停止 · " + step.title
            default: return step.title
            }
        }
    }

    /// Only real timestamps: shown once the step has both a start and an end.
    private var duration: String? {
        guard let end = step.finishedAt, step.state == .succeeded || step.state == .failed else { return nil }
        let seconds = end.timeIntervalSince(step.startedAt)
        return seconds >= 1 ? TraceDuration.text(seconds) : nil
    }

    @ViewBuilder private var glyph: some View {
        switch step.state {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: step.kind == .skill ? "sparkles" : step.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(.orange)
        case .needsPermission: Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(.orange)
        case .awaitingApproval: Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
        case .declined, .cancelled: Image(systemName: "xmark.circle").font(.system(size: 13)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !step.summary.isEmpty {
                Text(step.summary).font(.subheadline).foregroundStyle(step.state == .failed ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !step.facts.isEmpty, step.state == .succeeded { ResultFactsCard(title: step.title, symbol: step.symbol, facts: step.facts) }
            if !step.sources.isEmpty { SourceList(sources: step.sources) }
        }
    }

    @ViewBuilder private var actions: some View {
        switch step.state {
        case .awaitingApproval:
            HStack(spacing: 8) {
                Button { decide(true) } label: { Text("允许").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(busy)
                    .accessibilityIdentifier("agent.approve.\(step.id)")
                if simulation == nil, case let wider = platform.approvalScopes(forCall: step.id).filter({ $0 != .once }), !wider.isEmpty {
                    Menu {
                        Section("允许范围") { ForEach(wider, id: \.self) { scope in Button(scope.title) { decide(scope: scope) } } }
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 20) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(busy).accessibilityLabel("更多允许方式")
                }
                Button { decide(false) } label: { Text("不允许").font(.subheadline).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(busy)
                    .accessibilityIdentifier("agent.decline.\(step.id)")
            }
            .controlSize(.regular)
        default:
            switch step.recovery {
            case .openSystemSettings:
                Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: { Label("前往系统设置", systemImage: "gear").font(.subheadline) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(simulation != nil)
                    .accessibilityIdentifier("agent.openSettings")
            case .enableInITalk:
                Button { platform.enableCapability(named: step.permission ?? "") } label: {
                    Label("在 iTalk 中开启「\(step.permission ?? "")」", systemImage: "switch.2").font(.subheadline)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(simulation != nil)
            default: EmptyView()
            }
        }
    }

    private func decide(scope: ApprovalScope) {
        busy = true
        Task { failure = await platform.respond(toApproval: step.id, scope: scope); busy = false }
    }

    private func decide(_ approve: Bool) {
        if let simulation { simulation.decide(step.id, approve); return }
        busy = true
        Task {
            failure = await platform.respond(toApproval: step.id, approve: approve)
            busy = false
        }
    }
}

/// Approval and permission requests: the only bordered element in a trace, so the thing that needs the person stands out.
struct ActionCard<Actions: View>: View {
    let step: AgentStep
    let tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(step.state == .awaitingApproval ? "需要你确认" : "需要权限").font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(step.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !step.detail.isEmpty {
                Text(step.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(uiColor: .tertiaryLabel)).frame(width: 2) }
                    .textSelection(.enabled)
            }
            if !step.summary.isEmpty {
                Text(step.summary).font(.subheadline).foregroundStyle(step.state == .needsPermission ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MarkdownStyle.corner, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 0.75) }
    }
}

// MARK: - Structured results

/// Key figures from a tool (weather, calendar, travel time, health…) in one shared card style.
struct ResultFactsCard: View {
    let title: String
    let symbol: String
    let facts: [AgentStep.Fact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(fact.value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("result.facts")
    }
}

/// Numbered sources with title and host. Opens the page in the browser.
struct SourceList: View {
    let sources: [AgentStep.Source]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Rectangle().fill(MarkdownStyle.hairline).frame(height: 0.5).padding(.leading, 36) }
                SourceRow(source: source)
            }
        }
        .background(MarkdownStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("result.sources")
    }
}

struct SourceRow: View {
    let source: AgentStep.Source
    var body: some View {
        let url = URL(string: source.url)
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? source.url
        Button { if let url { UIApplication.shared.open(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(source.n)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).background(Circle().fill(MarkdownStyle.inlineCode))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title.isEmpty ? host : source.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !source.snippet.isEmpty { Text(source.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(url == nil)
        .accessibilityLabel("\(source.n). \(source.title)，\(host)")
    }
}

/// "来源 · 3" pill under an answer (as in ChatGPT); opens the full list.
struct SourcesPill: View {
    let sources: [AgentStep.Source]
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, s in
                        let host = URL(string: s.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "?"
                        Text(String(host.prefix(1)).uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                            .overlay { Circle().strokeBorder(MarkdownStyle.hairline, lineWidth: 0.5) }
                    }
                }
                Text("来源 · \(sources.count)").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
            .background(MarkdownStyle.surface, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("answer.sources")
        .sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView { SourceList(sources: sources).padding(16) }
                    .navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showing = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Text with a moving highlight for live work, as in Codex's "Thinking". Static under Reduce Motion.
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : (context.date.timeIntervalSinceReferenceDate / 2.2).truncatingRemainder(dividingBy: 1)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, .primary.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(40, geometry.size.width * 0.5))
                            .offset(x: (geometry.size.width + 80) * phase - 60)
                    }
                    .mask { Text(text).font(.subheadline.weight(.medium)).lineLimit(1) }
                }
        }
    }
}
