import SwiftUI
import AssistantCore

/// Developer tools are hidden from ordinary users: always in Debug builds, and in Release after tapping 版本 seven times.
enum DeveloperMode {
    static let key = "italk.developerMode"
    static var enabled: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: key)
        #endif
    }
}

/// Injected by the playground so the production trace components can run without touching the real runtime.
/// When present, approval and recovery buttons call `decide` instead of AgentPlatform.
struct SimulationHandler: @unchecked Sendable {
    var decide: (_ stepId: String, _ approve: Bool) -> Void
}
private struct SimulationKey: EnvironmentKey { static let defaultValue: SimulationHandler? = nil }
extension EnvironmentValues {
    var simulation: SimulationHandler? {
        get { self[SimulationKey.self] }
        set { self[SimulationKey.self] = newValue }
    }
}

struct DeveloperToolsView: View {
    var body: some View {
        List {
            Section {
                Label("这里的内容都是模拟数据，不代表真实运行结果，也不会调用模型、工具或系统权限。", systemImage: "testtube.2")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("对话") {
                NavigationLink { MessageScenarioPlayground() } label: { SettingsRow("消息场景测试", "slider.horizontal.3") }
                    .accessibilityIdentifier("dev.scenarios")
                NavigationLink { MessagePreviewView() } label: { SettingsRow("消息样式总览", "rectangle.stack") }
                    .accessibilityIdentifier("settings.messagePreview")
            }
            Section {
                NavigationLink { CompanionPlayground() } label: { SettingsRow("角色动作（新渲染）", "figure.wave") }
                    .accessibilityIdentifier("dev.rig")
                NavigationLink { CharacterMotionPreview(embedded: true) } label: { SettingsRow("动画测试（旧）", "face.smiling") }
                    .accessibilityIdentifier("dev.character")
            } header: { Text("伙伴") } footer: { Text("使用与语音界面相同的动画系统。") }
        }
        .navigationTitle("开发者工具").navigationBarTitleDisplayMode(.inline)
    }
}

/// Pick a scenario and inspect it through the real ConversationRow / AgentTraceView.
struct MessageScenarioPlayground: View {
    enum Scenario: String, CaseIterable, Identifiable {
        case finished, structured, running, reasoningLive, approval, permission, failedTool, interrupted, streaming, error
        var id: String { rawValue }
        var title: String {
            switch self {
            case .finished: "已完成"; case .structured: "结构化结果"; case .running: "运行中"; case .reasoningLive: "思考中"; case .approval: "等待确认"
            case .permission: "权限恢复"; case .failedTool: "工具失败"; case .interrupted: "已停止"; case .streaming: "流式回答"; case .error: "回答出错"
            }
        }
    }
    enum Content: String, CaseIterable, Identifiable {
        case plain, markdown, lists, swift, python, math, mathEdge, table, citations, image, generatedUI
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plain: "纯文本"; case .markdown: "长 Markdown"; case .lists: "嵌套列表"; case .swift: "Swift 代码"; case .python: "Python 代码"
            case .math: "公式"; case .mathEdge: "公式边界"; case .table: "宽表格"; case .citations: "引用"; case .image: "图片"; case .generatedUI: "生成界面"
            }
        }
        var text: String {
            switch self {
            case .plain: "周六晴到多云，周日可能有阵雨。建议周六出行，周日带伞。"
            case .markdown: """
                ## 周末行程建议

                **周六**适合户外，*周日*改为室内。下面按时间排好，`10:00` 前出发人最少。

                ### 周六
                1. 上午：西湖骑行，[苏堤](https://zh.wikipedia.org/wiki/苏堤)到白堤约 **5 公里**
                2. 中午：知味观，人均 ¥80
                3. 下午：中国美术学院象山校区

                > 出发前再确认一次天气。
                > > 雨天把骑行换成博物馆。

                ---

                最后，记得带上~~雨伞~~防晒霜。
                """
            case .lists: """
                出行清单：

                - [x] 订好酒店
                - [ ] 买高铁票
                  - 早上 8:05 的 G7311
                  - 备选：9:20 的 G7537
                - [ ] 准备证件
                  1. 身份证
                  2. 学生证（门票半价）
                     - 需要在有效期内

                * 另外：充电宝不超过 *20000mAh*
                """
            case .swift: """
                用 `async let` 并发拿两天的天气：

                ```swift
                struct Forecast: Decodable { let day: String; let summary: String; let high: Int; let precipitationProbability: Double }

                func weekend(for city: String) async throws -> [Forecast] {
                    async let saturday = weather.forecast(city: city, on: .saturday, units: .metric, includeHourly: false)
                    async let sunday = weather.forecast(city: city, on: .sunday, units: .metric, includeHourly: false)
                    return try await [saturday, sunday].sorted { $0.precipitationProbability < $1.precipitationProbability } // 晴天优先
                }
                ```
                """
            case .python: """
                ```python
                import statistics

                def rainy_days(forecast: list[dict], threshold: float = 0.6) -> list[str]:
                    \"\"\"Return the days whose precipitation probability is at or above the threshold.\"\"\"
                    return [d["day"] for d in forecast if d.get("precipitation", 0.0) >= threshold]

                print(rainy_days([{"day": "周六", "precipitation": 0.1}, {"day": "周日", "precipitation": 0.72}]))  # ['周日']
                print(statistics.mean([23, 20]))
                ```
                """
            case .math: """
                二次方程 $ax^2+bx+c=0$ 的解为：

                $$x=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}$$

                求和与积分：$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$，以及

                $$\\int_0^{\\infty} e^{-x^2}\\,dx=\\frac{\\sqrt{\\pi}}{2}, \\qquad \\lim_{n\\to\\infty}\\left(1+\\frac{1}{n}\\right)^n=e$$

                矩阵与分段函数：

                $$A=\\begin{pmatrix} \\alpha & \\beta \\\\ \\gamma & \\delta \\end{pmatrix},\\quad f(x)=\\begin{cases} x^2 & x\\ge 0 \\\\ -x & x<0 \\end{cases}$$

                其中 $\\Delta = b^2-4ac$，$\\vec{v}\\cdot\\hat{n}=0$。
                """
            case .mathEdge: """
                价格从 $5 涨到 $10，这不是公式。

                写错的公式会显示原文：

                $$\\frac{1}{2$$

                不支持的命令：$\\unknowncommand{x}$，正常的行内公式：\\(E=mc^2\\)。
                """
            case .table: """
                | 城市 | 周六天气 | 最高温 | 最低温 | 降水概率 | 风力 | 空气质量 | 建议 |
                | :--- | :---: | ---: | ---: | ---: | :---: | :---: | :--- |
                | 杭州 | 晴 | 23° | 15° | 10% | 3 级 | 良 | 适合骑行和爬山 |
                | 上海 | 多云 | 21° | 16° | 20% | 4 级 | 良 | 外滩夜景，注意保暖 |
                | 苏州 | 小雨 | 19° | 14° | 70% | 2 级 | 优 | 园林雨景，带伞 |
                """
            case .citations: "周日降雨概率较高[天气预报](https://weather.example/hangzhou)，以气象台最新发布为准[气象台](https://weather.example/alerts)。"
            case .generatedUI:
                // Renderer check only: this is the example from the generative_ui skill text, not a model output.
                "按你的情况调一下：\n\n```italk-ui\n" + #"{"id":"pg-loan","state":{"amount":300000,"years":20,"rate":3.5,"plan":"等额本息"},"root":{"type":"card","title":"月供计算","icon":"house","children":[{"type":"chips","bind":"plan","options":["等额本息","等额本金"]},{"type":"slider","label":"贷款金额","bind":"amount","min":50000,"max":2000000,"step":10000,"display":"{{round(amount/10000)}} 万"},{"type":"slider","label":"年限","bind":"years","min":5,"max":30,"step":1,"display":"{{years}} 年"},{"type":"slider","label":"年利率","bind":"rate","min":2,"max":6,"step":0.05,"display":"{{fixed(rate,2)}}%"},{"type":"grid","columns":2,"children":[{"type":"metric","label":"每月还款","value":"{{round(amount*(rate/1200)*pow(1+rate/1200,years*12)/(pow(1+rate/1200,years*12)-1))}}","unit":"元"},{"type":"metric","label":"总利息","value":"{{round(amount*(rate/1200)*pow(1+rate/1200,years*12)/(pow(1+rate/1200,years*12)-1)*years*12-amount)}}","unit":"元","tone":"warning"}]},{"type":"chart","kind":"bar","height":140,"data":[{"x":"本金","y":"{{amount}}"},{"x":"利息","y":"{{round(amount*(rate/1200)*pow(1+rate/1200,years*12)/(pow(1+rate/1200,years*12)-1)*years*12-amount)}}"}]},{"type":"button","label":"按这个方案做还款计划","style":"primary","action":{"type":"send","text":"请按{{plan}}、贷款 {{amount}} 元、{{years}} 年、年利率 {{rate}}% 做还款计划"}}]}}"# + "\n```"
            case .image: """
                这是苏堤春晓的示意图：

                ![苏堤春晓](https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/West_Lake_Hangzhou.jpg/640px-West_Lake_Hangzhou.jpg)
                """
            }
        }
    }

    @State private var scenario: Scenario
    @State private var content: Content
    @State private var trace: AgentTrace

    /// `-pgScenario <scenario> -pgContent <content>` open a specific state directly (scripted screenshots).
    init() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let s = value("-pgScenario").flatMap(Scenario.init(rawValue:)) ?? .finished
        _scenario = State(initialValue: s)
        _content = State(initialValue: value("-pgContent").flatMap(Content.init(rawValue:)) ?? .markdown)
        _trace = State(initialValue: Self.trace(s))
    }
    @State private var stream = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var resetToken = UUID()
    @State private var log: [String] = []

    private var turn: ConversationTurn {
        var turn = ConversationTurn(id: UUID(uuidString: "0D2B6E0C-6B8B-4F3C-9E0E-6F6C0E7D0001")!, question: "杭州周末适合出门吗？")
        switch scenario {
        case .streaming: turn.answer = stream; turn.state = stream.count < content.text.count ? .pending : .complete
        case .running, .reasoningLive, .approval, .permission:
            if trace.state == .finished { turn.answer = content.text; turn.state = .complete } else { turn.state = .pending }
        case .interrupted: turn.answer = String(content.text.prefix(24)); turn.state = .cancelled
        case .error: turn.answer = String(content.text.prefix(20)); turn.state = .failed; turn.failure = "当前模型暂不可用，请切换模型后重试。"
        default: turn.answer = content.text; turn.state = .complete
        }
        return turn
    }

    /// The row is shown exactly as in a conversation: same component, same page background and margins. Only the controls and the
    /// orange 模拟 tag around it belong to the playground.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("场景", selection: $scenario) { ForEach(Scenario.allCases) { Text($0.title).tag($0) } }
                    } label: { Label(scenario.title, systemImage: "slider.horizontal.3").font(.subheadline) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("dev.scenario.picker")
                    Menu {
                        Picker("回答内容", selection: $content) { ForEach(Content.allCases) { Text($0.title).tag($0) } }
                    } label: { Label(content.title, systemImage: "text.alignleft").font(.subheadline) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    Spacer(minLength: 0)
                    Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.bordered).buttonBorderShape(.circle)
                        .accessibilityLabel("重置场景")
                }
                Label("模拟数据，不会执行任何真实操作", systemImage: "testtube.2").font(.caption.weight(.medium)).foregroundStyle(.orange)
                ConversationRow(turn: turn, canRead: false, trace: scenario == .streaming || scenario == .error ? nil : trace,
                                retry: scenario == .error || scenario == .interrupted ? { log.append("点击「重试」") } : nil)
                    .id(resetToken)
                    .environment(\.simulation, SimulationHandler { id, approve in decide(id, approve) })
                    .accessibilityIdentifier("dev.scenario.row")
                if !log.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模拟操作记录").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(log, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("消息场景测试").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenario) { _, _ in reset() }
        .onChange(of: content) { _, _ in if scenario == .streaming { reset() } }
        .onAppear { if scenario == .streaming, stream.isEmpty { reset() } }
        .onDisappear { streamTask?.cancel() }
    }

    private func reset() {
        streamTask?.cancel(); log = []; trace = Self.trace(scenario); stream = ""; resetToken = UUID()
        guard scenario == .streaming else { return }
        let characters = Array(content.text)
        streamTask = Task { @MainActor in
            for end in stride(from: 3, through: characters.count + 2, by: 3) {
                guard !Task.isCancelled else { return }
                stream = String(characters.prefix(end))
                try? await Task.sleep(for: .milliseconds(70))
            }
            stream = content.text
        }
    }

    private func decide(_ id: String, _ approve: Bool) {
        guard let index = trace.items.firstIndex(where: { if case .step(let s) = $0 { s.id == id } else { false } }),
              case .step(var step) = trace.items[index] else { return }
        step.state = approve ? .succeeded : .declined
        step.summary = approve ? "示例：已允许（未执行真实操作）" : "示例：已拒绝"
        trace.items[index] = .step(step)
        trace.state = .finished; trace.finishedAt = .now
        log.append(approve ? "点击「允许」" : "点击「不允许」")
    }

    static func trace(_ scenario: Scenario) -> AgentTrace {
        let start = Date.now.addingTimeInterval(-9.5)
        var t = AgentTrace(startedAt: start)
        let skill = AgentStep(id: "s-skill", kind: .skill, state: .succeeded, title: "已加载技能：天气", startedAt: start, finishedAt: start)
        let thought = ReasoningBlock(id: "r1", text: "用户想知道周末是否适合出门。先查天气，再结合降雨概率给建议。", finished: scenario != .reasoningLive)
        switch scenario {
        case .finished:
            t.items = [.reasoning(thought), .step(skill),
                       .step(AgentStep(id: "s-weather", kind: .tool, state: .succeeded, title: "查询杭州天气", summary: "已取得周末天气",
                                       facts: [.init("周六", "23° 晴"), .init("周日", "20° 有雨")], symbol: "cloud.sun", startedAt: start, finishedAt: .now)),
                       .step(AgentStep(id: "s-search", kind: .web, state: .succeeded, title: "搜索网页", summary: "找到 1 个来源",
                                       sources: [.init(n: 1, title: "天气预报", url: "https://weather.example/hangzhou", snippet: "")], symbol: "globe", startedAt: start, finishedAt: .now))]
            t.state = .finished; t.finishedAt = .now; t.elapsed = 9.5
        case .structured:
            t.items = [.step(AgentStep(id: "s-skill2", kind: .skill, state: .succeeded, title: "已加载技能：日程", startedAt: start, finishedAt: start)),
                       .step(AgentStep(id: "s-cal", kind: .tool, state: .succeeded, title: "查看周末日程", detail: "10月31日–11月1日", summary: "周六下午有 1 个安排",
                                       facts: [.init("周六 15:00", "牙医复诊"), .init("空闲", "上午 · 周日全天")], symbol: "calendar",
                                       startedAt: start, finishedAt: start.addingTimeInterval(1.4))),
                       .step(AgentStep(id: "s-route", kind: .tool, state: .succeeded, title: "估算到西湖的路程", detail: "从当前位置", summary: "地铁 1 号线直达",
                                       facts: [.init("地铁", "28 分钟"), .init("驾车", "22 分钟"), .init("距离", "9.6 公里")], symbol: "map",
                                       startedAt: start, finishedAt: start.addingTimeInterval(2.1))),
                       .step(AgentStep(id: "s-web2", kind: .web, state: .succeeded, title: "搜索网页", detail: "西湖 周末 人流", summary: "找到 3 个来源",
                                       sources: [.init(n: 1, title: "西湖景区实时客流", url: "https://weather.example/westlake", snippet: "节假日上午 10 点后客流明显上升"),
                                                 .init(n: 2, title: "杭州地铁运营时间", url: "https://metro.example/hz"),
                                                 .init(n: 3, title: "周末天气预报", url: "https://weather.example/hangzhou")],
                                       symbol: "globe", startedAt: start, finishedAt: start.addingTimeInterval(3.2)))]
            t.state = .finished; t.finishedAt = .now; t.elapsed = 9.5
        case .running:
            t.items = [.step(skill), .step(AgentStep(id: "s-weather", kind: .tool, state: .running, title: "正在查询天气", detail: "杭州 · 未来两天", symbol: "cloud.sun", startedAt: start))]
            t.elapsed = 3
        case .reasoningLive:
            t.items = [.reasoning(thought)]; t.elapsed = 2
        case .approval:
            t.items = [.step(AgentStep(id: "s-send", kind: .approval, state: .awaitingApproval, title: "发送消息给小李", detail: "“周末一起去西湖吗？”", symbol: "paperplane", startedAt: start))]
            t.elapsed = 4
        case .permission:
            t.items = [.step(AgentStep(id: "s-loc", kind: .tool, state: .needsPermission, title: "读取位置", summary: "定位权限尚未开启",
                                       recovery: .openSystemSettings, permission: "位置", symbol: "location", startedAt: start))]
            t.elapsed = 2
        case .failedTool:
            t.items = [.step(AgentStep(id: "s-net", kind: .web, state: .failed, title: "搜索网页", summary: "网络暂时不可用，可稍后重试", recovery: .retry, symbol: "globe", startedAt: start, finishedAt: .now))]
            t.state = .failed; t.finishedAt = .now; t.elapsed = 5
        case .interrupted:
            t.items = [.reasoning(thought), .step(AgentStep(id: "s-weather", kind: .tool, state: .cancelled, title: "查询杭州天气", symbol: "cloud.sun", startedAt: start))]
            t.state = .cancelled; t.finishedAt = .now; t.elapsed = 4
        case .streaming, .error: break
        }
        return t
    }
}
