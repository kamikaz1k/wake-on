import AlarmKit
import SwiftUI
import UIKit

/// Pixie's alarms tool: alarms at a time (once or on weekdays) and countdown timers, set with
/// AlarmKit (iOS 26). They ring like the Clock app's, through Silent and Focus, but belong to
/// Pixie: they're listed and cancelled in Pixie (Settings › Alarms and timers) or by voice.
/// iOS asks permission the first time, which it only shows with Pixie on screen.
enum Alarms {
    static let toolName = "alarms"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Set, list or cancel the user's alarms and timers. They ring on the iPhone even when it's locked or silenced.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["set_alarm", "set_timer", "list", "cancel"]],
                "time": ["type": "string", "description": "set_alarm: the local time in 24-hour HH:mm, e.g. 06:45. Otherwise empty."],
                "days": ["type": "array", "items": ["type": "string", "enum": weekdayNames],
                         "description": "set_alarm: weekdays it repeats on; empty for once."],
                "seconds": ["type": "integer", "description": "set_timer: how long, in seconds. Otherwise 0."],
                "label": ["type": "string", "description": "A short name for it, e.g. Pasta or Gym; may be empty."],
                "id": ["type": "string", "description": "cancel: the id from list, or all. Otherwise empty."],
            ] as [String: Any],
            "required": ["action", "time", "days", "seconds", "label", "id"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    For alarms and timers call alarms: set_alarm with a 24-hour time (and days if it repeats) for \
    a clock time, set_timer with seconds for a length of time ("in 20 minutes", "a 10 minute \
    timer"). To cancel or change one, call list first, then cancel by id (and set the new one). \
    Confirm in a few words what was set, for example "Alarm set for 6:45 tomorrow morning."
    """

    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static let deniedText = "The user hasn't allowed Pixie to set alarms. Ask them to turn on Alarms in the iPhone's Settings › Pixie."
    static let backgroundText = "Pixie can only ask for permission to set alarms while it's open on screen. Ask the user to open Pixie and ask again."
    static let unsupportedText = "Alarms need iOS 26 or later. Tell the user."

    /// "06:45" → (6, 45).
    static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// When a one-off alarm at hour:minute rings next, from `now`.
    static func nextRing(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                          matchingPolicy: .nextTime) ?? now
    }

    /// "6:45 AM tomorrow", "9:00 PM today".
    static func describe(ring: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = ring.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(ring, inSameDayAs: now) { return "\(time) today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(ring, inSameDayAs: tomorrow) {
            return "\(time) tomorrow"
        }
        return "\(time) \(ring.formatted(.dateTime.weekday(.wide)))"
    }

    /// "10 minutes", "1 hour 30 minutes", "45 seconds".
    static func describe(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) second\(s == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// "weekdays", "every Monday and Friday".
    static func describe(days: [String]) -> String {
        let order = weekdayNames.filter(days.contains)
        if Set(order) == ["monday", "tuesday", "wednesday", "thursday", "friday"] { return "on weekdays" }
        if Set(order) == ["saturday", "sunday"] { return "on weekends" }
        if order.count == 7 { return "every day" }
        let names = order.map(\.capitalized)
        return "every " + (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "")
    }

    /// The tool's output for one call.
    @MainActor static func perform(_ arguments: [String: Any]) async -> String {
        guard #available(iOS 26.0, *) else { return unsupportedText }
        return await AlarmBook.shared.perform(arguments)
    }
}

/// What Pixie remembers about each alarm (AlarmKit doesn't hand labels back).
struct AlarmNote: Codable, Equatable {
    var label: String
    var timer: Bool
    /// When a timer rings; a one-off alarm's next ring.
    var rings: Date?
    var days: [String] = []
}

@available(iOS 26.0, *)
@MainActor
final class AlarmBook: ObservableObject {
    static let shared = AlarmBook()
    static let notesKey = "alarms.notes"
    static let weekday: [String: Locale.Weekday] = [
        "sunday": .sunday, "monday": .monday, "tuesday": .tuesday, "wednesday": .wednesday,
        "thursday": .thursday, "friday": .friday, "saturday": .saturday,
    ]
    private let manager = AlarmManager.shared

    @Published private(set) var alarms: [Alarm] = []
    @Published private(set) var notes: [UUID: AlarmNote] = AlarmBook.loadNotes()
    private var watching: Task<Void, Never>?

    /// Keeps `alarms` current and forgets notes of alarms that are gone.
    func watch() {
        guard watching == nil else { return }
        alarms = (try? manager.alarms) ?? []
        watching = Task { [weak self] in
            for await list in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                self.alarms = list
                let ids = Set(list.map(\.id))
                if self.notes.keys.contains(where: { !ids.contains($0) }) {
                    self.notes = self.notes.filter { ids.contains($0.key) }
                    self.saveNotes()
                }
            }
        }
    }

    func perform(_ arguments: [String: Any]) async -> String {
        let action = arguments["action"] as? String ?? ""
        let label = (arguments["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch action {
        case "list": return list()
        case "cancel": return cancel(arguments["id"] as? String ?? "")
        case "set_alarm", "set_timer":
            if let problem = await permission() { return problem }
            do {
                if action == "set_timer" {
                    let seconds = arguments["seconds"] as? Int ?? 0
                    guard seconds > 0 else { return "No length given for the timer. Ask the user how long." }
                    return try await setTimer(seconds: seconds, label: label)
                }
                guard let time = Alarms.parseTime(arguments["time"] as? String ?? "") else {
                    return "No time given for the alarm. Ask the user what time."
                }
                return try await setAlarm(hour: time.hour, minute: time.minute,
                                          days: (arguments["days"] as? [String] ?? []).filter(Alarms.weekdayNames.contains), label: label)
            } catch AlarmManager.AlarmError.maximumLimitReached {
                return "Pixie already has as many alarms as iOS allows. Ask the user to cancel some first."
            } catch {
                VoiceSessionController.appLog("alarm_failed \(error)")
                return "Couldn't set it just now. Tell the user."
            }
        default: return "Unknown action."
        }
    }

    /// nil when alarms are allowed; otherwise what to tell the user.
    func permission() async -> String? {
        switch manager.authorizationState {
        case .authorized: return nil
        case .denied: return Alarms.deniedText
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else { return Alarms.backgroundText }
            let state = (try? await manager.requestAuthorization()) ?? .denied
            return state == .authorized ? nil : Alarms.deniedText
        @unknown default: return Alarms.deniedText
        }
    }

    private func setAlarm(hour: Int, minute: Int, days: [String], label: String) async throws -> String {
        let weekdays: [Locale.Weekday] = days.compactMap { Self.weekday[$0] }
        let schedule = Alarm.Schedule.relative(.init(time: .init(hour: hour, minute: minute),
                                                     repeats: weekdays.isEmpty ? .never : .weekly(weekdays)))
        let title = label.isEmpty ? "Alarm" : label
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
            secondaryButtonBehavior: .countdown)
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert, countdown: .init(title: "Snoozing")),
                                         metadata: PixieAlarmMetadata(label: label), tintColor: PixieAlarmStyle.tint)
        let id = UUID()
        let config = AlarmManager.AlarmConfiguration<PixieAlarmMetadata>(
            countdownDuration: .init(preAlert: nil, postAlert: 9 * 60), schedule: schedule, attributes: attributes)
        _ = try await manager.schedule(id: id, configuration: config)
        let now = Date()
        let ring = Alarms.nextRing(hour: hour, minute: minute, after: now)
        remember(id, AlarmNote(label: label, timer: false, rings: days.isEmpty ? ring : nil, days: days))
        VoiceSessionController.appLog("alarm_set \(String(format: "%02d:%02d", hour, minute)) days=\(days.count)")
        let when = days.isEmpty ? Alarms.describe(ring: ring, now: now)
            : "\(ring.formatted(date: .omitted, time: .shortened)) \(Alarms.describe(days: days))"
        return "Alarm set for \(when)\(label.isEmpty ? "" : " (\(label))"). Tell the user in a few words. The call goes on."
    }

    private func setTimer(seconds: Int, label: String) async throws -> String {
        let title = LocalizedStringResource(stringLiteral: label.isEmpty ? "Timer" : label)
        let alert = AlarmPresentation.Alert(
            title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        let presentation = AlarmPresentation(
            alert: alert,
            countdown: .init(title: title, pauseButton: AlarmButton(text: "Pause", textColor: .white, systemImageName: "pause.fill")),
            paused: .init(title: "Paused", resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")))
        let attributes = AlarmAttributes(presentation: presentation, metadata: PixieAlarmMetadata(label: label, timer: true),
                                         tintColor: PixieAlarmStyle.tint)
        let id = UUID()
        _ = try await manager.schedule(id: id, configuration: .timer(duration: TimeInterval(seconds), attributes: attributes))
        let ring = Date().addingTimeInterval(TimeInterval(seconds))
        remember(id, AlarmNote(label: label, timer: true, rings: ring))
        VoiceSessionController.appLog("timer_set seconds=\(seconds)")
        return "Timer set for \(Alarms.describe(seconds: seconds))\(label.isEmpty ? "" : " (\(label))"), ringing at \(ring.formatted(date: .omitted, time: .shortened)). Tell the user in a few words. The call goes on."
    }

    func list() -> String {
        let current = (try? manager.alarms) ?? alarms
        guard !current.isEmpty else { return "The user has no alarms or timers set in Pixie." }
        let lines = current.map { "- id \($0.id.uuidString.prefix(8)): \(describe($0))" }
        return "Alarms and timers set in Pixie (ids are for cancel; don't read them aloud):\n" + lines.joined(separator: "\n")
    }

    /// "Alarm 6:45 AM on weekdays (Gym)", "Timer ringing at 3:42 PM (Pasta), paused".
    func describe(_ alarm: Alarm) -> String {
        let note = notes[alarm.id]
        var text: String
        if note?.timer == true || alarm.schedule == nil {
            text = "Timer" + (note?.rings.map { " ringing at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        } else if case .relative(let relative)? = alarm.schedule {
            let time = Calendar.current.date(from: DateComponents(hour: relative.time.hour, minute: relative.time.minute))?
                .formatted(date: .omitted, time: .shortened) ?? ""
            if case .weekly(let days) = relative.repeats {
                text = "Alarm \(time) \(Alarms.describe(days: days.compactMap { day in Self.weekday.first { $0.value == day }?.key }))"
            } else {
                text = "Alarm \(time)"
            }
        } else {
            text = "Alarm"
        }
        if let label = note?.label, !label.isEmpty { text += " (\(label))" }
        switch alarm.state {
        case .paused: text += ", paused"
        case .alerting: text += ", ringing now"
        default: break
        }
        return text
    }

    func cancel(_ id: String) -> String {
        let current = (try? manager.alarms) ?? alarms
        let wanted = id.trimmingCharacters(in: .whitespaces).lowercased()
        let targets = wanted == "all" ? current
            : current.filter { !wanted.isEmpty && $0.id.uuidString.lowercased().hasPrefix(wanted) }
        guard !targets.isEmpty else { return "No alarm with that id. Call list to see them." }
        let described = targets.map(describe)
        for alarm in targets { cancel(alarm.id) }
        return "Cancelled: \(described.joined(separator: "; ")). Tell the user in a few words."
    }

    func cancel(_ id: UUID) {
        try? manager.cancel(id: id)
        notes[id] = nil
        saveNotes()
        VoiceSessionController.appLog("alarm_cancelled")
    }

    private func remember(_ id: UUID, _ note: AlarmNote) {
        notes[id] = note
        saveNotes()
    }

    private static func loadNotes() -> [UUID: AlarmNote] {
        guard let data = UserDefaults.standard.data(forKey: notesKey),
              let stored = try? JSONDecoder().decode([String: AlarmNote].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func saveNotes() {
        let stored = Dictionary(uniqueKeysWithValues: notes.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.notesKey)
    }
}

/// Settings › Alarms and timers: what Pixie has set, swipe to cancel.
@available(iOS 26.0, *)
struct AlarmsView: View {
    @ObservedObject private var book = AlarmBook.shared

    var body: some View {
        List {
            if book.alarms.isEmpty {
                ContentUnavailableView("No Alarms", systemImage: "alarm",
                                       description: Text("Ask \(Agent.name) to set an alarm or a timer."))
            }
            ForEach(book.alarms) { alarm in
                Label(book.describe(alarm), systemImage: book.notes[alarm.id]?.timer == true || alarm.schedule == nil ? "timer" : "alarm")
            }
            .onDelete { offsets in
                for index in offsets { book.cancel(book.alarms[index].id) }
            }
        }
        .navigationTitle("Alarms and Timers")
        .onAppear { book.watch() }
    }
}
