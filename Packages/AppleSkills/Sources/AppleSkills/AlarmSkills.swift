import Foundation
import AgentRuntime
import UserNotifications
#if os(iOS)
import AlarmKit
import SwiftUI

struct ITalkAlarmMetadata: AlarmMetadata {
    var label: String
}
#endif

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: AlarmKit's alarm list has the system schedule and state but not the presentation title.
// Debug Goal: Keep labels for alarms made by iTalk while the system remains the source of truth for existence.
// Search Tags: alarmkit alarm label name metadata system list
// Invariants:
// - A label is attached only after the system reports a successful alarm.
// - A missing label is unknown, not a made-up title.
// Failure Modes:
// - Caching an alarm as a separate record can show reminders that no longer exist in AlarmKit.
public enum ITalkAlarmLabels {
    private static func key(_ id: UUID) -> String { "italk.alarm.label." + id.uuidString }
    public static func label(for id: UUID) -> String? { UserDefaults.standard.string(forKey: key(id)) }
    public static func save(_ label: String, for id: UUID) { UserDefaults.standard.set(label, forKey: key(id)) }
    public static func remove(for id: UUID) { UserDefaults.standard.removeObject(forKey: key(id)) }
}

enum AlarmSkills {
    static func parseClock(_ s: String?) -> (Int, Int)? {
        guard let s, let m = s.wholeMatch(of: /(\d{1,2})[:：](\d{2})/) , let h = Int(m.1), let mi = Int(m.2), (0..<24).contains(h), (0..<60).contains(mi) else { return nil }
        return (h, mi)
    }

    #if os(iOS)
    static func attributes(_ label: String, countdown: Bool) -> AlarmAttributes<ITalkAlarmMetadata> {
        let stop = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label), stopButton: stop)
        let presentation = countdown
            ? AlarmPresentation(alert: alert, countdown: .init(title: LocalizedStringResource(stringLiteral: label),
                                                              pauseButton: AlarmButton(text: "暂停", textColor: .white, systemImageName: "pause.fill")),
                                paused: .init(title: "已暂停", resumeButton: AlarmButton(text: "继续", textColor: .white, systemImageName: "play.fill")))
            : AlarmPresentation(alert: alert)
        return AlarmAttributes(presentation: presentation, metadata: ITalkAlarmMetadata(label: label), tintColor: .orange)
    }
    static func alarmJSON(_ a: Alarm) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(a.id.uuidString), "state": .string("\(a.state)")]
        switch a.schedule {
        case .fixed(let d)?: o["at"] = .string(ArgDate.iso(d))
        case .relative(let r)?: o["time"] = .string(String(format: "%02d:%02d", r.time.hour, r.time.minute)); o["repeats"] = .string("\(r.repeats)")
        default: break
        }
        if let c = a.countdownDuration?.preAlert { o["countdownSeconds"] = .number(c) }
        return .object(o)
    }
    #endif

    static let setAlarm = FnTool(ToolSpec(name: "alarm_set", description: "设置闹钟（系统级闹钟提醒，静音和专注模式下也会响）", parameters: [
        "time": ParamSpec(.string, "具体时刻用 24 小时制 HH:mm（下一次该时刻），例如“七点半”=07:30、“下午三点十分”=15:10；或带日期的 ISO-8601；经过多少秒或分钟请用 timer_start，不能用 HH:mm:ss", maxLength: 40),
        "label": ParamSpec(.string, "闹钟名称", required: false, maxLength: 40),
        "weekdays": ParamSpec(.array, "重复：1=周日 … 7=周六，可省略", required: false)
    ], permission: .lowRiskAction, capability: .alarms, systemPermission: .alarms, dataClass: .personal)) { a, ctx in
        #if os(iOS)
        let label = a.str("label") ?? "iTalk 闹钟"
        let id = stableUUID(ctx.idempotencyKey)
        if let existing = try? AlarmManager.shared.alarms.first(where: { $0.id == id }) { ITalkAlarmLabels.save(label, for: id); return out(["alarm": alarmJSON(existing)], "闹钟已设置", id: id.uuidString) }
        let schedule: Alarm.Schedule
        let days = (a["weekdays"]?.array ?? []).compactMap { $0.number.map(Int.init) }.filter { (1...7).contains($0) }
        if let (h, m) = parseClock(a.str("time")), a.str("time")!.count <= 5 {
            let map: [Int: Locale.Weekday] = [1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday, 5: .thursday, 6: .friday, 7: .saturday]
            schedule = .relative(.init(time: .init(hour: h, minute: m), repeats: days.isEmpty ? .never : .weekly(days.compactMap { map[$0] })))
        } else if let raw = a.str("time"), raw.contains("-") || raw.contains("/"),
                  let d = ArgDate.parse(raw, now: ctx.now), d > ctx.now {
            schedule = .fixed(d)
        } else { throw fail("闹钟时间无效或已过去。具体时刻请用 HH:mm 或带日期的时间；倒计时请使用 timer_start 的 seconds。") }
        let alarm: Alarm
        do { alarm = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: schedule, attributes: attributes(label, countdown: false))) }
        catch { throw fail("系统拒绝了这个闹钟：\(error.localizedDescription)（\(String(describing: type(of: error)))）。请确认已在 设置 › iTalk 中允许“闹钟与提醒”。") }
        // Verify with the system: the alarm must be readable back, otherwise it was not really created.
        guard (try? AlarmManager.shared.alarms.contains { $0.id == id }) == true else { throw fail("闹钟已提交但无法在 iTalk 中核对，不能确认创建成功。") }
        ITalkAlarmLabels.save(label, for: id)
        let when: String
        switch schedule { case .fixed(let d): when = ArgDate.spoken(d); case .relative(let r): when = String(format: "%02d:%02d", r.time.hour, r.time.minute) + (days.isEmpty ? "" : "（每周重复）"); @unknown default: when = "" }
        return ToolOutput(value: .object(["alarm": alarmJSON(alarm), "verified": .bool(true)]), summary: "已设置并核对闹钟「\(label)」\(when)", externalId: id.uuidString,
                          facts: [.init("时间", when), .init("名称", label), .init("状态", "已核对"), .init("管理位置", "iTalk 设置 › 闹钟与计时；不在时钟 App 中")])
        #else
        throw fail("此平台不支持闹钟")
        #endif
    }

    static let startTimer = FnTool(ToolSpec(name: "timer_start", description: "开始倒计时（结束时以闹钟方式提醒）", parameters: [
        "seconds": ParamSpec(.integer, "时长（秒）", minimum: 1, maximum: 86400),
        "label": ParamSpec(.string, "名称", required: false, maxLength: 40)
    ], permission: .lowRiskAction, capability: .alarms, systemPermission: .alarms)) { a, ctx in
        #if os(iOS)
        guard let s = a.num("seconds") else { throw fail("缺少时长") }
        let label = a.str("label") ?? "计时"
        let id = stableUUID(ctx.idempotencyKey)
        if let existing = try? AlarmManager.shared.alarms.first(where: { $0.id == id }) { ITalkAlarmLabels.save(label, for: id); return out(["timer": alarmJSON(existing)], "计时已开始", id: id.uuidString) }
        let alarm: Alarm
        do { alarm = try await AlarmManager.shared.schedule(id: id, configuration: .timer(duration: s, attributes: attributes(label, countdown: true))) }
        catch { throw fail("系统拒绝了这个计时：\(error.localizedDescription)（\(String(describing: type(of: error)))）。请确认已在 设置 › iTalk 中允许“闹钟与提醒”。") }
        guard (try? AlarmManager.shared.alarms.contains { $0.id == id }) == true else { throw fail("计时已提交但在系统中读不到，可能没有创建成功。") }
        ITalkAlarmLabels.save(label, for: id)
        let text = "\(Int(s) / 60) 分 \(Int(s) % 60) 秒"
        return ToolOutput(value: .object(["timer": alarmJSON(alarm), "endsAt": .string(ArgDate.iso(ctx.now.addingTimeInterval(s))), "verified": .bool(true)]),
                          summary: "已开始并核对 \(text) 倒计时", externalId: id.uuidString, facts: [.init("时长", text), .init("结束", ArgDate.spoken(ctx.now.addingTimeInterval(s))), .init("管理位置", "iTalk 设置 › 闹钟与计时；不在时钟 App 中")])
        #else
        throw fail("此平台不支持计时")
        #endif
    }

    static let listAlarms = FnTool(ToolSpec(name: "alarm_list", description: "列出 iTalk 设置的闹钟和计时", permission: .readOnly, capability: .alarms, systemPermission: .alarms)) { _, _ in
        #if os(iOS)
        let list = try AlarmManager.shared.alarms
        return out(["alarms": .array(list.map(alarmJSON)), "note": .string("这里只能看到 iTalk 创建的闹钟与计时，它们不会出现在系统时钟 App 的列表中。")], "\(list.count) 个闹钟/计时")
        #else
        throw fail("此平台不支持闹钟")
        #endif
    }

    static let cancelAlarm = FnTool(ToolSpec(name: "alarm_cancel", description: "取消 iTalk 设置的闹钟或计时", parameters: [
        "id": ParamSpec(.string, "alarm_list 返回的 id", maxLength: 40)
    ], permission: .lowRiskAction, capability: .alarms, systemPermission: .alarms)) { a, _ in
        #if os(iOS)
        guard let s = a.str("id"), let id = UUID(uuidString: s) else { throw fail("id 无效") }
        try AlarmManager.shared.cancel(id: id)
        ITalkAlarmLabels.remove(for: id)
        return out(["cancelled": .bool(true)], "已取消")
        #else
        throw fail("此平台不支持闹钟")
        #endif
    }

    static let scheduleNotification = FnTool(ToolSpec(name: "notification_schedule", description: "在本机指定时间弹出一条通知提醒用户自己；不能给别人发消息或短信", parameters: [
        "title": ParamSpec(.string, "标题", maxLength: 80),
        "body": ParamSpec(.string, "内容", required: false, maxLength: 300),
        "at": ParamSpec(.string, "时间 ISO-8601 或 HH:mm", required: false, maxLength: 40),
        "afterSeconds": ParamSpec(.integer, "或：多少秒后", required: false, minimum: 1, maximum: 31_536_000)
    ], permission: .lowRiskAction, capability: .notifications, systemPermission: .notifications, dataClass: .personal)) { a, ctx in
        guard let title = a.str("title") else { throw fail("缺少标题") }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = a.str("body") ?? ""; content.sound = .default
        let trigger: UNNotificationTrigger
        if let s = a.num("afterSeconds") { trigger = UNTimeIntervalNotificationTrigger(timeInterval: s, repeats: false) }
        else if let d = ArgDate.parse(a.str("at"), now: ctx.now), d > ctx.now {
            trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d), repeats: false)
        } else { throw fail("需要未来的时间") }
        // The idempotency key is the request id: scheduling twice replaces instead of duplicating.
        let id = "italk-" + ctx.idempotencyKey
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return out(["id": .string(id)], "已安排通知「\(title)」", id: id)
    }

    static let listNotifications = FnTool(ToolSpec(name: "notification_list", description: "列出 iTalk 待发送的通知", permission: .readOnly, capability: .notifications, systemPermission: .notifications)) { _, _ in
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { $0.identifier.hasPrefix("italk-") }
        return out(["pending": .array(pending.map { r in
            var o: [String: JSONValue] = ["id": .string(r.identifier), "title": .string(r.content.title)]
            if let t = r.trigger as? UNCalendarNotificationTrigger, let d = t.nextTriggerDate() { o["at"] = .string(ArgDate.iso(d)) }
            if let t = r.trigger as? UNTimeIntervalNotificationTrigger, let d = t.nextTriggerDate() { o["at"] = .string(ArgDate.iso(d)) }
            return .object(o)
        })], "\(pending.count) 条待发送通知")
    }

    static let cancelNotification = FnTool(ToolSpec(name: "notification_cancel", description: "取消一条待发送通知", parameters: [
        "id": ParamSpec(.string, "notification_list 返回的 id", maxLength: 120)
    ], permission: .lowRiskAction, capability: .notifications, systemPermission: .notifications)) { a, _ in
        guard let id = a.str("id"), id.hasPrefix("italk-") else { throw fail("只能取消 iTalk 的通知") }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        return out(["cancelled": .bool(true)], "已取消通知")
    }
}
