import XCTest
@testable import WakeOn

/// Pixie's calendar and reminders tools: dates in and out, short ids, offered with instructions.
@MainActor
final class CalendarTests: XCTestCase {
    private let toronto = TimeZone(identifier: "America/Toronto")!

    func testParse() throws {
        let timed = try XCTUnwrap(PixieCalendar.parse("2026-11-27T12:30", timeZone: toronto))
        XCTAssertFalse(timed.allDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timed.date),
                       DateComponents(year: 2026, month: 11, day: 27, hour: 12, minute: 30))
        XCTAssertTrue(try XCTUnwrap(PixieCalendar.parse("2026-11-27", timeZone: toronto)).allDay)
        XCTAssertNil(PixieCalendar.parse("tomorrow", timeZone: toronto))
        XCTAssertNil(PixieCalendar.parse("", timeZone: toronto))
    }

    func testDescribe() throws {
        let start = try XCTUnwrap(PixieCalendar.parse("2026-11-27T12:00", timeZone: toronto)).date
        let text = PixieCalendar.describe(start: start, end: start.addingTimeInterval(3600), allDay: false, timeZone: toronto)
        XCTAssertTrue(text.hasPrefix("Friday, November 27, 12:00"), text)
        XCTAssertTrue(text.contains("1:00"), text)
        XCTAssertEqual(PixieCalendar.describe(start: start, end: start, allDay: true, timeZone: toronto), "Friday, November 27, all day")
    }

    func testShortIDsAreStable() {
        XCTAssertEqual(PixieCalendar.shortID("abc@1"), PixieCalendar.shortID("abc@1"))
        XCTAssertNotEqual(PixieCalendar.shortID("abc@1"), PixieCalendar.shortID("abc@2"), "each occurrence of a repeating event gets its own id")
        XCTAssertEqual(PixieCalendar.shortID("abc@1").count, 6)
    }

    func testToolsAreOfferedWithInstructions() throws {
        let session = try XCTUnwrap(LiveVoiceConfig().requestBody(sdp: "v=0")["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let names = ((responses["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("calendar") && names.contains("reminders"))
        XCTAssertTrue((responses["instructions"] as? String)?.contains("call reminders") == true)
        var off = LiveVoiceConfig()
        off.calendar = false
        XCTAssertFalse(off.backendInstructions().contains("call calendar"))
    }

    func testChatLabels() {
        func label(_ name: String, _ args: String) -> String {
            ChatToolSteps.label(ChatItem.Tool(name: name, arguments: args, result: nil, state: .done))
        }
        XCTAssertEqual(label("calendar", #"{"action":"add","title":"Lunch with Sam"}"#), "Added “Lunch with Sam” to your calendar")
        XCTAssertEqual(label("calendar", #"{"action":"list"}"#), "Checked your calendar")
        XCTAssertEqual(label("reminders", #"{"action":"add","title":"Call Mom"}"#), "Added reminder “Call Mom”")
        XCTAssertEqual(label("reminders", #"{"action":"complete"}"#), "Completed a reminder")
    }
}
