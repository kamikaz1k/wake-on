import XCTest
@testable import WakeOn

final class ContactsTests: XCTestCase {
    func testNumbersBecomeDialable() {
        XCTAssertEqual(PixieContacts.dialable("+1 (416) 555-0199"), "+14165550199")
        XCTAssertEqual(PixieContacts.dialable("416.555.0199 ext *2#"), "4165550199*2#")
        XCTAssertNil(PixieContacts.dialable("n/a"))
        XCTAssertEqual(PixieContacts.url(for: "+14165550199", method: "phone")?.absoluteString, "tel://+14165550199")
        XCTAssertEqual(PixieContacts.url(for: "+14165550199", method: "facetime")?.scheme, "facetime")
        XCTAssertEqual(PixieContacts.url(for: "+14165550199", method: "facetime_audio")?.scheme, "facetime-audio")
    }

    func testSearchResultsNeverCarryNumbers() {
        let id = PixieContacts.shortID("contact-1", "+14165550199")
        XCTAssertEqual(id.count, 6)
        XCTAssertEqual(id, PixieContacts.shortID("contact-1", "+14165550199"))
        let text = PixieContacts.describe([("Sam Lee", [(id, "mobile")]), ("Sam Park", [])], query: "Sam")
        XCTAssertTrue(text.contains("Sam Lee: mobile (id \(id))"))
        XCTAssertTrue(text.contains("Sam Park: no phone number"))
        XCTAssertFalse(text.contains("555"))
        XCTAssertTrue(PixieContacts.describe([], query: "Zed").contains("No contacts match"))
    }

    func testToolIsOptional() throws {
        var config = LiveVoiceConfig()
        XCTAssertTrue(try tools(config).contains(PixieContacts.toolName))
        XCTAssertTrue(config.backendInstructions().contains("only call contacts with action call after the user says yes"))
        config.contacts = false
        XCTAssertFalse(try tools(config).contains(PixieContacts.toolName))
        XCTAssertFalse(config.backendInstructions().contains("action search"))
    }

    func testContactsPermissionIsDescribed() {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription"))
    }

    private func tools(_ config: LiveVoiceConfig) throws -> [String] {
        let session = try XCTUnwrap(config.requestBody(sdp: "v=0")["session"] as? [String: Any])
        let responses = (session["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        return ((responses?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }
}

final class ThinkingSoundTests: XCTestCase {
    func testPlaysOnlyWhilePixieIsQuietDuringALookup() {
        XCTAssertTrue(ThinkingSound.shouldPlay(live: true, lookingUpFor: 3, pixieQuietFor: 1.5, connectionLost: false, muted: false))
        // Pixie's "one moment" first, then the sound.
        XCTAssertFalse(ThinkingSound.shouldPlay(live: true, lookingUpFor: 3, pixieQuietFor: 0.5, connectionLost: false, muted: false))
        XCTAssertFalse(ThinkingSound.shouldPlay(live: true, lookingUpFor: nil, pixieQuietFor: 5, connectionLost: false, muted: false))
        XCTAssertFalse(ThinkingSound.shouldPlay(live: true, lookingUpFor: 31, pixieQuietFor: 5, connectionLost: false, muted: false))
        XCTAssertFalse(ThinkingSound.shouldPlay(live: true, lookingUpFor: 3, pixieQuietFor: 5, connectionLost: true, muted: false))
        XCTAssertFalse(ThinkingSound.shouldPlay(live: true, lookingUpFor: 3, pixieQuietFor: 5, connectionLost: false, muted: true))
        XCTAssertFalse(ThinkingSound.shouldPlay(live: false, lookingUpFor: 3, pixieQuietFor: 5, connectionLost: false, muted: false))
    }

    func testLoopsAreQuietAndEndInSilence() {
        for style in ThinkingSound.Style.allCases {
            let loop = ThinkingSound.loop(style, sampleRate: 48_000)
            XCTAssertGreaterThan(loop.count, 48_000, "\(style)")
            let peak = Double(loop.map { abs(Int($0)) }.max() ?? 0) / 32767
            // Well under Pixie's voice, so it never sounds like speech.
            XCTAssertLessThan(peak, 0.1, "\(style)")
            XCTAssertGreaterThan(peak, 0.02, "\(style)")
            // The last 0.3 s is a rest, so stopping at the end of a loop never cuts a note.
            XCTAssertTrue(loop.suffix(14_400).allSatisfy { abs(Int($0)) < 40 }, "\(style)")
        }
    }
}

final class AppWarningsTests: XCTestCase {
    func testNothingToReportWhenAllIsWell() {
        XCTAssertEqual(AppWarnings.list(.init()), [])
    }

    func testWarningsTheAppIsHolding() {
        var state = AppWarnings.State()
        state.connection = .weak
        state.roundTripMs = 950
        state.voiceNoteWaiting = true
        state.chatTokens = ChatTokens.limit + 1200
        state.lowPower = true
        state.thermal = .serious
        state.denied = ["contacts"]
        state.interface = "cellular"
        let warnings = AppWarnings.list(state)
        XCTAssertEqual(warnings.first, "Weak call connection (round trip 950 ms)")
        XCTAssertTrue(warnings.contains("Voice note waiting to be sent"))
        XCTAssertTrue(warnings.contains { $0.hasPrefix("Chat is ~5.2k tokens") })
        XCTAssertTrue(warnings.contains("Low Power Mode on"))
        XCTAssertTrue(warnings.contains("iPhone is hot (thermal state serious)"))
        XCTAssertTrue(warnings.contains("Access turned off: contacts"))
        XCTAssertEqual(warnings.last, "Network: cellular")
        XCTAssertEqual(AppWarnings.list(.init(online: false)), ["No internet connection"])
    }

    func testFeedbackCarriesTheWarnings() {
        let body = Feedback.body(feedback: "It kept cutting out", context: "", app: "1.0 (7)", warnings: ["Weak call connection"])
        XCTAssertEqual(body["warnings"] as? [String], ["Weak call connection"])
    }
}
