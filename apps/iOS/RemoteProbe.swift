#if DEBUG || ITALK_PROBES
import Foundation
import UIKit
import os
import AgentRuntime
import RemoteAgent

/// On-device check of the Mac link, launched with arguments (nothing is shown in the UI):
///   -remoteProbe <italk-pair://…>     pair with the computer that displayed the link, run a read task, an edit task that needs approval (approved
///                                     here), a suspend/resume of the event stream, and leave a slow task running; report in Documents/remote-probe.json
///   -remoteProbeFinish                after the app was killed and relaunched: read the slow task the Mac kept running and report how it ended
@MainActor enum RemoteProbe {
    struct Step: Codable { var name: String; var ok: Bool; var ms: Int; var detail: String }
    struct Report: Codable { var device: String; var date: Date; var steps: [Step]; var note: String }

    private static let log = Logger(subsystem: "com.italk.assistant", category: "remote-probe")
    private static var reportURL: URL { URL.documentsDirectory.appendingPathComponent("remote-probe.json") }
    private static var slowTaskURL: URL { URL.documentsDirectory.appendingPathComponent("remote-probe-slow-task.txt") }

    static func run(center: RemoteDeviceCenter, link: String, workspace: String?) async {
        var steps: [Step] = []
        func record(_ name: String, _ started: Date, ok: Bool, _ detail: String) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            steps.append(Step(name: name, ok: ok, ms: ms, detail: detail)); log.info("\(name, privacy: .public) ok=\(ok) \(ms)ms \(detail, privacy: .public)")
            write(steps)
        }
        #if !targetEnvironment(simulator)
        let keepAlive = ProbeKeepAlive(); keepAlive.start(); defer { keepAlive.stop() }      // the simulator has no lock screen to outlive (and its audio server deadlocks under load)
        #endif

        var t0 = Date()
        await center.beginPairing(payload: link)
        var deviceId: String?
        if case .paired(let id) = center.pairing { deviceId = id }
        record("pair", t0, ok: deviceId != nil, "\(center.pairing)")
        guard let deviceId, let device = center.device(deviceId) else { return }
        record("status", t0, ok: device.state.isOnline, "\(RemoteDevicesView.stateText(device.state)); models: \(device.models.map(\.name).joined(separator: ", "))")
        guard device.state.isOnline, let model = device.models.first else { return }

        // 1. A read-only task: streamed answer, no approval.
        t0 = Date()
        var firstEvent: Date?
        do {
            let task = try await center.submitTask(deviceId: deviceId, prompt: "用一句话说明你运行在哪台电脑上（用工具查看当前工作文件夹的内容再回答）。", modelId: model.id)
            var answeredApprovals = Set<String>()
            let finished = await waitForTask(center, task.id, timeout: 120) {
                if firstEvent == nil, (center.transcript(for: task.id)?.lastSeq ?? 0) > 1 { firstEvent = Date() }
                // The model may run a command to look around; the Mac asks, and this probe answers like a person who agrees.
                if let ask = center.transcript(for: task.id)?.pendingApproval, ask.risk != .sensitive, answeredApprovals.insert(ask.id).inserted {
                    Task { try? await center.respondToApproval(taskId: task.id, approve: true) }
                }
            }
            let t = center.transcript(for: task.id)
            record("read-task", t0, ok: finished == .completed && !(t?.answer.isEmpty ?? true), "state=\(String(describing: finished)) firstEventMs=\(firstEvent.map { Int($0.timeIntervalSince(t0) * 1000) } ?? -1) steps=\(t?.steps.count ?? 0) approvalsAnswered=\(answeredApprovals.count) answer=\((t?.answer ?? "").prefix(160))")
        } catch { record("read-task", t0, ok: false, "\(error.localizedDescription)") }

        // 2. An edit task: must wait for approval; nothing is written until it is given.
        if let workspace {
            t0 = Date()
            do {
                let task = try await center.submitTask(deviceId: deviceId, prompt: "在工作文件夹里创建文件 italk-probe.txt，内容是 hello from iPhone。完成后告诉我。", modelId: model.id,
                                                       options: .init(workingFolder: workspace, permissionMode: "ask", title: "创建 italk-probe.txt"))
                var asked = false
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline, center.transcript(for: task.id)?.isFinished != true {
                    if let approval = center.transcript(for: task.id)?.pendingApproval, !asked {
                        asked = true
                        record("approval-visible", t0, ok: approval.risk == .modify, "\(approval.summary)")
                        try await center.respondToApproval(taskId: task.id, approve: true)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let t = center.transcript(for: task.id)
                record("edit-task", t0, ok: asked && t?.phase == .completed, "asked=\(asked) phase=\(String(describing: t?.phase)) answer=\((t?.answer ?? "").prefix(120))")
            } catch { record("edit-task", t0, ok: false, "\(error.localizedDescription)") }
        }

        // 3. Resume: the app goes to the background mid-task (iOS drops the sockets), the Mac keeps working, and on return nothing is lost.
        t0 = Date()
        do {
            let task = try await center.submitTask(deviceId: deviceId, prompt: "请从 1 数到 12，每个数字单独写一行，并在每行后面加一个简短的词语。", modelId: model.id)
            let start = Date()
            while (center.transcript(for: task.id)?.lastSeq ?? 0) < 3, Date().timeIntervalSince(start) < 30 { try? await Task.sleep(for: .milliseconds(50)) }
            let seqBefore = center.transcript(for: task.id)?.lastSeq ?? 0
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            try? await Task.sleep(for: .seconds(4))                            // "away": the Mac finishes the task meanwhile
            let seqAway = center.transcript(for: task.id)?.lastSeq ?? 0
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            _ = await waitForTask(center, task.id, timeout: 60) { }
            let live = center.transcript(for: task.id)
            let replay = await center.replayTranscript(task.id)
            record("resume", t0, ok: live?.phase == .completed && live?.answer == replay?.answer && live?.lastSeq == replay?.lastSeq && seqAway == seqBefore,
                   "eventsBeforeAway=\(seqBefore) whileAway=\(seqAway) finalLive=\(live?.lastSeq ?? 0) finalReplay=\(replay?.lastSeq ?? 0) identical=\(live?.answer == replay?.answer) chars=\(live?.answer.count ?? 0)")
        } catch { record("resume", t0, ok: false, "\(error.localizedDescription)") }

        // 4. Leave a long task running on the Mac, then end the app: the Mac must finish it without the phone.
        t0 = Date()
        do {
            let task = try await center.submitTask(deviceId: deviceId, prompt: "请写一篇约一千五百字的文章，介绍杭州的春天，分五段，每段都要有具体的景点和细节。", modelId: model.id, options: .init(title: "长任务（App 被结束）"))
            try? task.id.write(to: slowTaskURL, atomically: true, encoding: .utf8)
            record("left-running", t0, ok: true, "task \(task.id) submitted; terminate the app now")
            try? await Task.sleep(for: .seconds(600))        // wait to be killed; the Mac must finish the task without the phone
        } catch { record("left-running", t0, ok: false, "\(error.localizedDescription)") }
    }

    static func finish(center: RemoteDeviceCenter) async {
        var steps: [Step] = (try? JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL)))?.steps ?? []
        let t0 = Date()
        guard let id = try? String(contentsOf: slowTaskURL, encoding: .utf8) else { return }
        await center.refresh()
        await center.openTask(id)
        let state = await waitForTask(center, id, timeout: 120) { }
        let t = center.transcript(for: id)
        steps.append(Step(name: "survived-app-kill", ok: state == .completed && (t?.answer.count ?? 0) > 100, ms: Int(Date().timeIntervalSince(t0) * 1000),
                          detail: "state=\(String(describing: state)) chars=\(t?.answer.count ?? 0) events=\(t?.lastSeq ?? 0)"))
        write(steps, note: "after relaunch")
    }

    private static func waitForTask(_ center: RemoteDeviceCenter, _ id: String, timeout: TimeInterval, tick: () -> Void) async -> RemoteTaskState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            tick()
            if let info = center.allTasks.first(where: { $0.id == id }), info.state.isFinished, center.transcript(for: id)?.isFinished == true { return info.state }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return center.allTasks.first { $0.id == id }?.state
    }

    private static func write(_ steps: [Step], note: String = "") {
        let report = Report(device: UIDevice.current.name, date: Date(), steps: steps, note: note)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: reportURL, options: .atomic) }
    }
}
#endif
