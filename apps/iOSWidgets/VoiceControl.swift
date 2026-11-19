import WidgetKit
import SwiftUI

@main struct VoiceControls: WidgetBundle {
    var body: some Widget { VoiceControl(); AgentLiveActivity(); ITalkAlarmActivity() }
}
struct VoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.italk.voice.control") {
            ControlWidgetButton(action: OpenAssistantIntent()) { Label("与 iTalk 对话", systemImage: "mic") }
        }
        .displayName("开始对话").description("打开 iTalk，在前台开始普通话对话。")
    }
}
