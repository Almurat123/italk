#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity / Dynamic Island for a voice session or agent task. Shown state only: a Live Activity never keeps the
/// agent running (iOS decides how long the app may run in the background).
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case listening, thinking, working, speaking, waitingForYou, paused, done, failed }
        var phase: Phase
        /// One short line, no conversation content beyond the tool's own summary ("正在查询日程", "需要你确认").
        var detail: String
        /// 0…1 for tasks with known progress (downloads, multi-step runs); nil = indeterminate.
        var progress: Double?
        var updatedAt: Date
    }
    /// "语音对话" or a conversation title chosen by the app (never the person's message text).
    var title: String
    var startedAt: Date
}

extension AgentActivityAttributes.ContentState.Phase {
    var label: String {
        switch self {
        case .listening: "正在听"; case .thinking: "正在思考"; case .working: "正在执行"; case .speaking: "正在回答"
        case .waitingForYou: "需要你确认"; case .paused: "已暂停"; case .done: "已完成"; case .failed: "未完成"
        }
    }
    var symbol: String {
        switch self {
        case .listening: "waveform"; case .thinking: "ellipsis"; case .working: "gearshape.2"; case .speaking: "speaker.wave.2.fill"
        case .waitingForYou: "hand.tap"; case .paused: "pause.fill"; case .done: "checkmark"; case .failed: "exclamationmark.triangle"
        }
    }
}
#endif
