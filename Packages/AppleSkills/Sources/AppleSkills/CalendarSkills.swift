import Foundation
import AgentRuntime
import EventKit

/// EventKit store shared by calendar and reminder tools (EKEventStore is expensive and must outlive its objects).
final class EventStoreBox: @unchecked Sendable {
    static let shared = EventStoreBox()
    let store = EKEventStore()
    private let lock = NSLock()
    /// After the person grants access in this process, the store must re-read sources.
    func refreshed() -> EKEventStore { lock.withLock { store.refreshSourcesIfNecessary(); return store } }
}

enum CalendarSkills {
    static func eventJSON(_ e: EKEvent) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(e.calendarItemIdentifier), "title": .string(e.title ?? ""),
            "start": .string(ArgDate.iso(e.startDate)), "end": .string(ArgDate.iso(e.endDate)), "allDay": .bool(e.isAllDay),
            "calendar": .string(e.calendar?.title ?? "")]
        if let l = e.location, !l.isEmpty { o["location"] = .string(l) }
        if let n = e.notes, !n.isEmpty { o["notes"] = .string(String(n.prefix(200))) }
        return .object(o)
    }
    static func reminderJSON(_ r: EKReminder) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(r.calendarItemIdentifier), "title": .string(r.title ?? ""), "completed": .bool(r.isCompleted),
                                      "list": .string(r.calendar?.title ?? ""), "priority": .number(Double(r.priority))]
        if let d = r.dueDateComponents?.date ?? r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { o["due"] = .string(ArgDate.iso(d)) }
        return .object(o)
    }

    static let listEvents = FnTool(ToolSpec(name: "calendar_list_events", description: "查询日历中的日程", parameters: [
        "start": ParamSpec(.string, "开始时间 ISO-8601 或 yyyy-MM-dd，默认现在", required: false, maxLength: 40),
        "end": ParamSpec(.string, "结束时间，默认开始后 7 天", required: false, maxLength: 40),
        "query": ParamSpec(.string, "按标题/地点筛选", required: false, maxLength: 60),
        "limit": ParamSpec(.integer, "最多返回条数，默认 20", required: false, minimum: 1, maximum: 100)
    ], permission: .readOnly, capability: .calendar, systemPermission: .calendar, dataClass: .personal)) { a, ctx in
        let store = EventStoreBox.shared.refreshed()
        let start = ArgDate.parse(a.str("start"), now: ctx.now) ?? ctx.now
        let end = ArgDate.parse(a.str("end"), now: ctx.now) ?? start.addingTimeInterval(7 * 86400)
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw fail("时间范围无效（最长一年）") }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        if let q = a.str("query")?.lowercased() { events = events.filter { ($0.title ?? "").lowercased().contains(q) || ($0.location ?? "").lowercased().contains(q) } }
        let list = events.prefix(a.int("limit") ?? 20)
        return out(["events": .array(list.map(eventJSON)), "count": .number(Double(events.count)),
                    "range": .string("\(ArgDate.iso(start)) – \(ArgDate.iso(end))")], "找到 \(events.count) 个日程")
    }

    static let createEvent = FnTool(ToolSpec(name: "calendar_create_event", description: "在日历中创建日程（需要用户确认）", parameters: [
        "title": ParamSpec(.string, "标题", maxLength: 200),
        "start": ParamSpec(.string, "开始时间 ISO-8601", maxLength: 40),
        "end": ParamSpec(.string, "结束时间，默认 1 小时后", required: false, maxLength: 40),
        "allDay": ParamSpec(.boolean, "全天", required: false),
        "location": ParamSpec(.string, "地点", required: false, maxLength: 200),
        "notes": ParamSpec(.string, "备注", required: false, maxLength: 1000),
        "alertMinutesBefore": ParamSpec(.integer, "提前几分钟提醒", required: false, minimum: 0, maximum: 10080)
    ], permission: .confirmBeforeAction, capability: .calendar, systemPermission: .calendar, dataClass: .personal),
    describe: { a in "创建日程「\(a.str("title") ?? "")」\(ArgDate.parse(a.str("start")).map { "，\(ArgDate.spoken($0))" } ?? "")\(a.str("location").map { "，地点 \($0)" } ?? "")" },
    reconcile: { key in
        guard let id = await IdempotencyMap.shared.get(key), let e = EventStoreBox.shared.refreshed().calendarItem(withIdentifier: id) as? EKEvent else { return nil }
        return out(["event": eventJSON(e), "verified": .bool(true)], "日程已存在（恢复后核对）", id: id)
    }) { a, ctx in
        let store = EventStoreBox.shared.refreshed()
        if let id = await IdempotencyMap.shared.get(ctx.idempotencyKey), let e = store.calendarItem(withIdentifier: id) as? EKEvent {
            return out(["event": eventJSON(e), "verified": .bool(true)], "日程已创建", id: id)
        }
        guard let title = a.str("title"), let start = ArgDate.parse(a.str("start"), now: ctx.now) else { throw fail("需要标题和明确的开始时间") }
        let end = ArgDate.parse(a.str("end"), now: ctx.now) ?? start.addingTimeInterval(3600)
        guard end >= start else { throw fail("结束时间早于开始时间") }
        guard let cal = store.defaultCalendarForNewEvents else { throw fail("没有可写入的日历") }
        let e = EKEvent(eventStore: store)
        e.title = title; e.startDate = start; e.endDate = end; e.isAllDay = a.flag("allDay") ?? false; e.calendar = cal
        e.location = a.str("location"); e.notes = a.str("notes")
        if let m = a.int("alertMinutesBefore") { e.addAlarm(EKAlarm(relativeOffset: TimeInterval(-60 * m))) }
        try store.save(e, span: .thisEvent, commit: true)
        await IdempotencyMap.shared.set(ctx.idempotencyKey, e.calendarItemIdentifier)
        guard let saved = store.calendarItem(withIdentifier: e.calendarItemIdentifier) as? EKEvent else { throw fail("已提交但无法验证日程") }
        return out(["event": eventJSON(saved), "verified": .bool(true)], "已创建日程「\(title)」\(ArgDate.spoken(start))", id: saved.calendarItemIdentifier)
    }

    static let deleteEvent = FnTool(ToolSpec(name: "calendar_delete_event", description: "删除一个日程（需要用户确认）", parameters: [
        "id": ParamSpec(.string, "calendar_list_events 返回的 id", maxLength: 200)
    ], permission: .confirmBeforeAction, capability: .calendar, systemPermission: .calendar, dataClass: .personal),
    describe: { a in
        let e = a.str("id").flatMap { EventStoreBox.shared.store.calendarItem(withIdentifier: $0) as? EKEvent }
        return "删除日程「\(e?.title ?? "未知")」\(e.map { "（\(ArgDate.spoken($0.startDate))）" } ?? "")"
    }) { a, _ in
        let store = EventStoreBox.shared.refreshed()
        guard let id = a.str("id") else { throw fail("缺少 id") }
        guard let e = store.calendarItem(withIdentifier: id) as? EKEvent else {
            return out(["deleted": .bool(true), "note": .string("该日程已不存在")], "日程已不存在")
        }
        let title = e.title ?? ""
        try store.remove(e, span: .thisEvent, commit: true)
        return out(["deleted": .bool(true), "title": .string(title)], "已删除日程「\(title)」")
    }

    static let listReminders = FnTool(ToolSpec(name: "reminders_list", description: "查询提醒事项", parameters: [
        "includeCompleted": ParamSpec(.boolean, "包含已完成，默认否", required: false),
        "list": ParamSpec(.string, "列表名称", required: false, maxLength: 60),
        "dueBefore": ParamSpec(.string, "截止早于此时间", required: false, maxLength: 40),
        "limit": ParamSpec(.integer, "默认 30", required: false, minimum: 1, maximum: 200)
    ], permission: .readOnly, capability: .reminders, systemPermission: .reminders, dataClass: .personal)) { a, ctx in
        let store = EventStoreBox.shared.refreshed()
        var cals = store.calendars(for: .reminder)
        if let name = a.str("list") { cals = cals.filter { $0.title.contains(name) } }
        let pred = (a.flag("includeCompleted") ?? false) ? store.predicateForReminders(in: cals)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: ArgDate.parse(a.str("dueBefore"), now: ctx.now), calendars: cals)
        let limit = a.int("limit") ?? 30
        // Convert on the callback queue: EKReminder objects never cross concurrency domains.
        let (list, total): ([JSONValue], Int) = await withCheckedContinuation { c in
            store.fetchReminders(matching: pred) { r in let all = r ?? []; c.resume(returning: (all.prefix(limit).map(reminderJSON), all.count)) }
        }
        return out(["reminders": .array(list), "count": .number(Double(total)),
                    "lists": .array(store.calendars(for: .reminder).map { .string($0.title) })], "\(total) 条提醒")
    }

    static let completeReminder = FnTool(ToolSpec(name: "reminders_complete", description: "把提醒标记为已完成", parameters: [
        "id": ParamSpec(.string, "reminders_list 返回的 id", maxLength: 200),
        "completed": ParamSpec(.boolean, "默认 true；false 为取消完成", required: false)
    ], permission: .lowRiskAction, capability: .reminders, systemPermission: .reminders, dataClass: .personal)) { a, _ in
        let store = EventStoreBox.shared.refreshed()
        guard let id = a.str("id"), let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw fail("找不到这个提醒") }
        r.isCompleted = a.flag("completed") ?? true
        try store.save(r, commit: true)
        return out(["reminder": reminderJSON(r)], "\(r.isCompleted ? "已完成" : "已恢复")「\(r.title ?? "")」")
    }
}

/// `create_reminder` (AgentRuntime's confirm-before-action tool) backed by EventKit.
struct EventKitReminderStore: ReminderStore {
    func create(title: String, due: Date?, idempotencyKey: String) async throws -> String {
        let store = EventStoreBox.shared.refreshed()
        if let id = await IdempotencyMap.shared.get(idempotencyKey), store.calendarItem(withIdentifier: id) != nil { return id }
        guard let cal = store.defaultCalendarForNewReminders() else { throw fail("没有可写入的提醒列表") }
        let r = EKReminder(eventStore: store)
        r.title = title; r.calendar = cal
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        await IdempotencyMap.shared.set(idempotencyKey, r.calendarItemIdentifier)
        return r.calendarItemIdentifier
    }
    func exists(idempotencyKey: String) async -> String? {
        guard let id = await IdempotencyMap.shared.get(idempotencyKey), EventStoreBox.shared.refreshed().calendarItem(withIdentifier: id) != nil else { return nil }
        return id
    }
    func verify(id: String) async -> Bool { EventStoreBox.shared.refreshed().calendarItem(withIdentifier: id) is EKReminder }
}
