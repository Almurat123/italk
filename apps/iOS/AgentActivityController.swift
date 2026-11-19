import Foundation
import ActivityKit
import Observation
import os
import AssistantCore

/// Keeps one Live Activity in sync with the voice session and running agent tasks. It only reflects real state; it does
/// not extend how long iOS lets the app run.
@MainActor final class AgentActivityController {
    private weak var model: AppModel?
    private weak var platform: AgentPlatform?
    private var activity: Activity<AgentActivityAttributes>?
    private var last: AgentActivityAttributes.ContentState?
    private let log = Logger(subsystem: "com.italk.assistant", category: "live-activity")

    func track(model: AppModel, platform: AgentPlatform) {
        self.model = model; self.platform = platform
        // Activities left over from a previous process (crash, update) are ended, never shown stale.
        for a in Activity<AgentActivityAttributes>.activities {
            nonisolated(unsafe) let old = a      // Activity is not Sendable in this SDK; it is only used for this one call
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        observe()
    }

    private func observe() {
        guard let model, let platform else { return }
        withObservationTracking {
            _ = model.session.phase; _ = model.voice.state; _ = platform.activeConversations; _ = platform.traces; _ = platform.statusLine
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh(); self?.observe() }
        }
        refresh()
    }

    private func desired() -> AgentActivityAttributes.ContentState? {
        guard let model, let platform else { return nil }
        let waiting = platform.pendingApprovalCount > 0
        let now = Date.now
        if waiting { return .init(phase: .waitingForYou, detail: "回到 iTalk 确认后继续", progress: nil, updatedAt: now) }
        if model.voice.isActive {
            switch model.session.phase {
            case .listening, .preparing, .idle: return .init(phase: .listening, detail: "直接说话即可", progress: nil, updatedAt: now)
            case .finalizing, .thinking: return .init(phase: platform.statusLine == nil ? .thinking : .working, detail: platform.statusLine ?? "正在思考", progress: nil, updatedAt: now)
            case .speaking, .synthesizing: return .init(phase: .speaking, detail: "说话即可打断", progress: nil, updatedAt: now)
            default: return .init(phase: .paused, detail: "点按继续", progress: nil, updatedAt: now)
            }
        }
        if !platform.activeConversations.isEmpty {
            let n = platform.activeConversations.count
            return .init(phase: platform.statusLine == nil ? .thinking : .working, detail: platform.statusLine ?? (n > 1 ? "\(n) 个任务进行中" : "正在回答"), progress: nil, updatedAt: now)
        }
        return nil
    }

    private func refresh() {
        let next = desired()
        if var n = next, var l = last { n.updatedAt = .distantPast; l.updatedAt = .distantPast; if n == l { return } }
        last = next
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let state = next {
            let content = ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(15 * 60))
            if let activity { nonisolated(unsafe) let a = activity; Task { await a.update(content) } }
            else {
                do { activity = try Activity.request(attributes: AgentActivityAttributes(title: model?.voice.isActive == true ? "语音对话" : "iTalk 任务", startedAt: .now), content: content) }
                catch { log.error("live activity request failed: \(error.localizedDescription, privacy: .public)") }
            }
        } else if let activity {
            self.activity = nil
            nonisolated(unsafe) let a = activity
            Task { await a.end(ActivityContent(state: .init(phase: .done, detail: "已结束", progress: nil, updatedAt: .now), staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(4))) }
        }
    }
}
