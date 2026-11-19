import Foundation
import EventKit

struct ActionDraft: Identifiable {
    enum Kind { case calendar, reminder }
    let id = UUID()
    let kind: Kind
    var title: String
    var date: Date = .now.addingTimeInterval(3600)
    let expiresAt = Date.now.addingTimeInterval(60)
}

@MainActor final class CalendarService {
    private let store = EKEventStore()
    func authorize(reminders: Bool) async throws {
        let granted = try await (reminders ? store.requestFullAccessToReminders() : store.requestFullAccessToEvents())
        guard granted else { throw AppFailure.message("未获得系统访问许可，请在系统设置中检查。") }
    }
    func summary(reminders: Bool) async throws -> String {
        guard EKEventStore.authorizationStatus(for: reminders ? .reminder : .event) == .fullAccess else { throw AppFailure.message("请先在隐私设置中授权日历或提醒事项。") }
        if reminders {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let titles: [String] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { items in
                    continuation.resume(returning: Array((items ?? []).prefix(3).map { $0.title ?? "未命名提醒" }))
                }
            }
            return titles.isEmpty ? "目前没有可读取的未完成提醒。" : "未完成的提醒包括：" + titles.joined(separator: "；") + "。"
        }
        let start = Calendar.current.startOfDay(for: .now), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        return events.isEmpty ? "今天没有可读取的日程。" : "今天的日程包括：" + events.prefix(3).map { "\($0.startDate.formatted(date: .omitted, time: .shortened))，\($0.title ?? "未命名日程")" }.joined(separator: "；") + "。"
    }
    func save(_ draft: ActionDraft) throws -> String {
        #if os(watchOS)
        throw AppFailure.message("watchOS 不允许通过 EventKit 写入日历或提醒。请在 iPhone 上确认并保存。")
        #else
        guard Date.now < draft.expiresAt else { throw AppFailure.message("确认已过期，请重新发起。") }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.count <= 300 else { throw AppFailure.message("请填写有效标题。") }
        if draft.kind == .reminder {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let calendar = store.defaultCalendarForNewReminders() else { throw AppFailure.message("提醒事项未授权或没有可写列表。") }
            let reminder = EKReminder(eventStore: store); reminder.title = draft.title; reminder.calendar = calendar
            reminder.url = URL(string: "italk://action/\(draft.id)")
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: draft.date)
            reminder.addAlarm(EKAlarm(absoluteDate: draft.date))
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, let calendar = store.defaultCalendarForNewEvents else { throw AppFailure.message("日历未授权或没有可写日历。") }
        let event = EKEvent(eventStore: store); event.title = draft.title; event.calendar = calendar
        event.startDate = draft.date; event.endDate = draft.date.addingTimeInterval(3600)
        event.url = URL(string: "italk://action/\(draft.id)")
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
        #endif
    }
}
