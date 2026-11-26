import CryptoKit
import EventKit
import UIKit

/// Pixie's calendar and reminders tools, on Apple's Calendar and Reminders through EventKit.
/// Every calendar added to the iPhone counts: iCloud, Google, Outlook. iOS asks for full
/// access the first time each is used, and only shows that prompt with Pixie on screen.
enum PixieCalendar {
    static let calendarTool = "calendar"
    static let remindersTool = "reminders"

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "name": calendarTool,
            "description": "Read, add or delete events in the user's calendars (iCloud, Google, Outlook and others on their iPhone).",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list", "add", "delete"]],
                    "start": ["type": "string", "description": "list: first day, YYYY-MM-DD. add: local start, YYYY-MM-DDTHH:mm, or YYYY-MM-DD for all day. Otherwise empty."],
                    "end": ["type": "string", "description": "add: local end, YYYY-MM-DDTHH:mm; empty for one hour (or one day if all day). Otherwise empty."],
                    "days": ["type": "integer", "description": "list: how many days from start, 1 for just that day. Otherwise 0."],
                    "title": ["type": "string", "description": "add: the event's title. Otherwise empty."],
                    "location": ["type": "string", "description": "add: where, or empty."],
                    "notes": ["type": "string", "description": "add: notes, or empty."],
                    "calendar": ["type": "string", "description": "add: a calendar's name from list, or empty for the default."],
                    "id": ["type": "string", "description": "delete: the event's id from list. Otherwise empty."],
                ] as [String: Any],
                "required": ["action", "start", "end", "days", "title", "location", "notes", "calendar", "id"],
                "additionalProperties": false,
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": remindersTool,
            "description": "Read, add or complete the user's reminders in Apple Reminders.",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list", "add", "complete"]],
                    "title": ["type": "string", "description": "add: what to be reminded of. Otherwise empty."],
                    "due": ["type": "string", "description": "add: local time to remind, YYYY-MM-DDTHH:mm, or YYYY-MM-DD for a day, or empty for none."],
                    "list": ["type": "string", "description": "add or list: a list's name, e.g. Groceries; empty for the default (add) or all lists (list)."],
                    "id": ["type": "string", "description": "complete: the reminder's id from list. Otherwise empty."],
                ] as [String: Any],
                "required": ["action", "title", "due", "list", "id"],
                "additionalProperties": false,
            ] as [String: Any],
        ],
    ]

    static let delegationInstructions = """
    For the user's schedule call calendar: list to see events (start day and days), add for a new \
    event (local times; ask if the time is unclear), delete only when they ask to remove one (list \
    first to get its id). For "remind me to…" and to-do or shopping lists call reminders: add with \
    a due time when they give one ("at 5", "tomorrow morning" is 09:00), list, or complete by id \
    from list. Say what you added or found in a few words, with day and time; don't read ids aloud.
    """

    static let deniedText = "The user hasn't allowed Pixie to use their %@. Ask them to turn it on in the iPhone's Settings › Pixie."
    static let backgroundText = "Pixie can only ask for access to %@ while it's open on screen. Ask the user to open Pixie and ask again."

    /// "2026-11-27T12:00" or "2026-11-27" (all day) in local time.
    static func parse(_ text: String, timeZone: TimeZone = .current) -> (date: Date, allDay: Bool)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for (format, allDay) in [("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd", true)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, allDay) }
        }
        return nil
    }

    /// "Friday, November 27, 12:00 – 1:00 PM", "Friday, November 27, all day".
    static func describe(start: Date, end: Date, allDay: Bool, timeZone: TimeZone = .current) -> String {
        var day = Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide).month(.wide).day()
        day.timeZone = timeZone
        if allDay { return "\(start.formatted(day)), all day" }
        let formatter = DateIntervalFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(day)), \(formatter.string(from: start, to: end))"
        }
        formatter.dateStyle = .medium
        return formatter.string(from: start, to: end)
    }

    /// The same six characters for the same item in every list.
    static func shortID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func perform(_ name: String, _ arguments: [String: Any]) async -> String {
        name == calendarTool ? await CalendarBook.shared.calendar(arguments) : await CalendarBook.shared.reminders(arguments)
    }
}

/// One EKEventStore for the app, and the ids Pixie handed out in its last lists.
@MainActor
final class CalendarBook {
    static let shared = CalendarBook()
    private let store = EKEventStore()
    /// What the last lists showed, by short id, for delete and complete. The objects themselves,
    /// since every occurrence of a repeating event shares one identifier.
    private var shownEvents: [String: EKEvent] = [:]
    private var shownReminders: [String: EKReminder] = [:]

    // MARK: Calendar

    func calendar(_ args: [String: Any]) async -> String {
        if let problem = await access(.event) { return problem }
        let action = args["action"] as? String ?? ""
        switch action {
        case "list":
            let first = PixieCalendar.parse(args["start"] as? String ?? "")?.date ?? Date()
            let start = Calendar.current.startOfDay(for: first)
            let days = max(1, min(31, args["days"] as? Int ?? 1))
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
            let names = writableCalendars.map(\.title)
            let header = "Calendars the user can add to: \(names.joined(separator: ", ")).\n"
            guard !events.isEmpty else { return header + "No events in those \(days) day\(days == 1 ? "" : "s")." }
            let lines = events.prefix(40).map { event -> String in
                let id = PixieCalendar.shortID("\(event.eventIdentifier ?? event.title ?? "")@\(event.startDate.timeIntervalSince1970)")
                shownEvents[id] = event
                var line = "- id \(id): \(PixieCalendar.describe(start: event.startDate, end: event.endDate, allDay: event.isAllDay)) \(event.title ?? "Untitled")"
                if let place = event.location, !place.isEmpty { line += " at \(place)" }
                return line + " [\(event.calendar.title)]"
            }
            return header + "Events (ids are for delete; don't read them aloud):\n" + lines.joined(separator: "\n")
        case "add":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return "No title for the event. Ask the user what it is." }
            guard let start = PixieCalendar.parse(args["start"] as? String ?? "") else { return "No start time. Ask the user when." }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.isAllDay = start.allDay
            event.startDate = start.date
            if let end = PixieCalendar.parse(args["end"] as? String ?? "")?.date, end > start.date {
                event.endDate = end
            } else {
                event.endDate = start.allDay ? start.date : start.date.addingTimeInterval(3600)
            }
            let place = (args["location"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !place.isEmpty { event.location = place }
            let notes = (args["notes"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !notes.isEmpty { event.notes = notes }
            let wanted = (args["calendar"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !wanted.isEmpty {
                guard let match = writableCalendars.first(where: { $0.title.localizedCaseInsensitiveCompare(wanted) == .orderedSame })
                        ?? writableCalendars.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) else {
                    return "No calendar called \(wanted). The user's calendars: \(writableCalendars.map(\.title).joined(separator: ", ")). Ask which one."
                }
                event.calendar = match
            } else {
                guard let calendar = store.defaultCalendarForNewEvents else { return "The user has no calendar to add to." }
                event.calendar = calendar
            }
            do {
                try store.save(event, span: .thisEvent)
            } catch {
                VoiceSessionController.appLog("calendar_add_failed \(error)")
                return "Couldn't add the event just now. Tell the user."
            }
            VoiceSessionController.appLog("calendar_added")
            return "Added “\(title)” to \(event.calendar.title): \(PixieCalendar.describe(start: event.startDate, end: event.endDate, allDay: event.isAllDay)). Tell the user in a few words. The call goes on."
        case "delete":
            guard let event = shownEvents[(args["id"] as? String ?? "").lowercased()] else {
                return "No event with that id. Call list first."
            }
            let what = "“\(event.title ?? "Untitled")”, \(PixieCalendar.describe(start: event.startDate, end: event.endDate, allDay: event.isAllDay))"
            do {
                try store.remove(event, span: .thisEvent)
            } catch {
                return "Couldn't delete it: the calendar may be read-only. Tell the user."
            }
            VoiceSessionController.appLog("calendar_deleted")
            return "Deleted \(what). Tell the user in a few words."
        default: return "Unknown action."
        }
    }

    private var writableCalendars: [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
    }

    // MARK: Reminders

    func reminders(_ args: [String: Any]) async -> String {
        if let problem = await access(.reminder) { return problem }
        let wantedList = (args["list"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let lists = store.calendars(for: .reminder)
        let list = wantedList.isEmpty ? nil
            : lists.first { $0.title.localizedCaseInsensitiveCompare(wantedList) == .orderedSame }
            ?? lists.first { $0.title.localizedCaseInsensitiveContains(wantedList) }
        if !wantedList.isEmpty, list == nil {
            return "No reminders list called \(wantedList). The user's lists: \(lists.map(\.title).joined(separator: ", ")). Ask which one, or leave it empty for the default."
        }
        switch args["action"] as? String ?? "" {
        case "list":
            let reminders = await incomplete(in: list.map { [$0] })
            guard !reminders.isEmpty else { return "No open reminders\(list.map { " in \($0.title)" } ?? "")." }
            let lines = reminders.prefix(40).map { reminder -> String in
                let id = PixieCalendar.shortID(reminder.calendarItemIdentifier)
                shownReminders[id] = reminder
                var line = "- id \(id): \(reminder.title ?? "Untitled")"
                if let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) {
                    line += ", due \(due.formatted(date: .abbreviated, time: reminder.dueDateComponents?.hour == nil ? .omitted : .shortened))"
                }
                return line + " [\(reminder.calendar.title)]"
            }
            return "Open reminders (ids are for complete; don't read them aloud):\n" + lines.joined(separator: "\n")
        case "add":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return "Nothing to add. Ask the user what to be reminded of." }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            guard let calendar = list ?? store.defaultCalendarForNewReminders() else { return "The user has no reminders list." }
            reminder.calendar = calendar
            var when = ""
            if let due = PixieCalendar.parse(args["due"] as? String ?? "") {
                let parts: Set<Calendar.Component> = due.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
                reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due.date)
                if !due.allDay { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
                when = ", " + due.date.formatted(date: .complete, time: due.allDay ? .omitted : .shortened)
            }
            do {
                try store.save(reminder, commit: true)
            } catch {
                VoiceSessionController.appLog("reminder_add_failed \(error)")
                return "Couldn't add the reminder just now. Tell the user."
            }
            VoiceSessionController.appLog("reminder_added due=\(!when.isEmpty)")
            return "Added reminder “\(title)” to \(calendar.title)\(when). Tell the user in a few words. The call goes on."
        case "complete":
            guard let reminder = shownReminders[(args["id"] as? String ?? "").lowercased()] else {
                return "No reminder with that id. Call list first."
            }
            reminder.isCompleted = true
            do { try store.save(reminder, commit: true) } catch { return "Couldn't mark it done just now. Tell the user." }
            return "Marked “\(reminder.title ?? "Untitled")” done. Tell the user in a few words."
        default: return "Unknown action."
        }
    }

    private func incomplete(in lists: [EKCalendar]?) async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let found: [EKReminder] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { done.resume(returning: $0 ?? []) }
        }
        return found.sorted {
            let a = $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
            let b = $1.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
            return a < b
        }
    }

    // MARK: Shared

    /// nil when allowed; otherwise what to tell the user.
    private func access(_ type: EKEntityType) async -> String? {
        let what = type == .event ? "calendar" : "reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return nil
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else { return String(format: PixieCalendar.backgroundText, what) }
            let granted = (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
            return granted ? nil : String(format: PixieCalendar.deniedText, what)
        default: return String(format: PixieCalendar.deniedText, what)
        }
    }
}
