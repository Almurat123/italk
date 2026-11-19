import AppIntents

enum AssistantDestination: String, AppEnum {
    case voice
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "助手页面")
    static let caseDisplayRepresentations: [AssistantDestination: DisplayRepresentation] = [.voice: "语音助手"]
}

struct OpenAssistantIntent: OpenIntent {
    static let title: LocalizedStringResource = "开始与 iTalk 对话"
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "页面") var target: AssistantDestination
    init() { target = .voice }
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "italk://voice/start")!))
    }
}

struct AssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAssistantIntent(), phrases: ["和 \(.applicationName) 对话", "打开 \(.applicationName) 语音"], shortTitle: "开始对话", systemImageName: "mic")
    }
}
