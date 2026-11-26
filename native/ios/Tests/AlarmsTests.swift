import XCTest
@testable import WakeOn

/// Pixie's alarms tool: times and lengths are read and said back right, and the tool is offered
/// with its instructions on iOS 26.
@MainActor
final class AlarmsTests: XCTestCase {
    func testParseTime() {
        XCTAssertTrue(Alarms.parseTime("06:45")! == (6, 45))
        XCTAssertTrue(Alarms.parseTime(" 23:05 ")! == (23, 5))
        XCTAssertNil(Alarms.parseTime("24:00"))
        XCTAssertNil(Alarms.parseTime("7"))
        XCTAssertNil(Alarms.parseTime(""))
    }

    func testDescribeSeconds() {
        XCTAssertEqual(Alarms.describe(seconds: 600), "10 minutes")
        XCTAssertEqual(Alarms.describe(seconds: 5400), "1 hour 30 minutes")
        XCTAssertEqual(Alarms.describe(seconds: 45), "45 seconds")
        XCTAssertEqual(Alarms.describe(seconds: 61), "1 minute 1 second")
    }

    func testDescribeDays() {
        XCTAssertEqual(Alarms.describe(days: ["friday", "monday", "tuesday", "wednesday", "thursday"]), "on weekdays")
        XCTAssertEqual(Alarms.describe(days: ["sunday", "saturday"]), "on weekends")
        XCTAssertEqual(Alarms.describe(days: ["friday", "monday"]), "every Monday and Friday")
        XCTAssertEqual(Alarms.describe(days: ["tuesday"]), "every Tuesday")
    }

    func testNextRingIsTodayOrTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 22, minute: 0))!
        let later = Alarms.nextRing(hour: 23, minute: 30, after: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: later), 26)
        let morning = Alarms.nextRing(hour: 6, minute: 45, after: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: morning), 27)
        XCTAssertTrue(Alarms.describe(ring: morning, now: now, calendar: calendar).hasSuffix("tomorrow"))
        XCTAssertTrue(Alarms.describe(ring: later, now: now, calendar: calendar).hasSuffix("today"))
    }

    func testToolIsOfferedOnIOS26() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        let session = try XCTUnwrap(LiveVoiceConfig().requestBody(sdp: "v=0")["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        XCTAssertTrue(((responses["tools"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "alarms" })
        XCTAssertTrue((responses["instructions"] as? String)?.contains("set_timer with seconds") == true)

        var off = LiveVoiceConfig()
        off.alarms = false
        let without = try XCTUnwrap(((off.requestBody(sdp: "v=0")["session"] as? [String: Any])?["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        XCTAssertFalse(((without["tools"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "alarms" })
    }

    func testChatLabels() {
        func label(_ args: String) -> String {
            ChatToolSteps.label(ChatItem.Tool(name: "alarms", arguments: args, result: nil, state: .done))
        }
        XCTAssertEqual(label(#"{"action":"set_alarm","time":"06:45","label":"Gym"}"#), "Set an alarm for 06:45 “Gym”")
        XCTAssertEqual(label(#"{"action":"set_timer","seconds":600,"label":""}"#), "Set a timer")
        XCTAssertEqual(label(#"{"action":"list"}"#), "Checked your alarms")
    }

    /// The backend is told the local date and time, so "7 tomorrow" and "tonight" work.
    func testBackendKnowsTheTime() {
        let toronto = TimeZone(identifier: "America/Toronto")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 4, minute: 30))!
        let line = LiveVoiceConfig.clockLine(now, timeZone: toronto)
        XCTAssertTrue(line.hasPrefix("Now: Thursday, November 26, 2026"), line)
        XCTAssertTrue(line.contains("4:30"), line)
        XCTAssertTrue(line.hasSuffix("(America/Toronto)."), line)
        XCTAssertTrue(LiveVoiceConfig().backendInstructions().contains("\nNow: "))
    }
}
