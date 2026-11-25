import XCTest
@testable import WakeOn

/// App Review: nothing goes to OpenAI before the user agrees (5.1.2(i)), and Pixie's replies
/// can be reported (1.2, 4.7.1) without the reply leaving the phone in a link.
@MainActor
final class AIConsentTests: XCTestCase {
    private var saved: Any?

    override func setUp() async throws {
        saved = UserDefaults.standard.object(forKey: AIConsent.key)
        UserDefaults.standard.removeObject(forKey: AIConsent.key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(saved, forKey: AIConsent.key)
        VoiceSessionController.shared.consentNeeded = false
    }

    func testStartWithoutConsentAsksInsteadOfCalling() {
        let voice = VoiceSessionController.shared
        XCTAssertFalse(AIConsent.given)
        voice.start(trigger: "in_app")
        XCTAssertTrue(voice.consentNeeded, "The permission sheet comes up")
        XCTAssertEqual(voice.phase, .idle, "No call starts before the user agrees")
        voice.answerConsent(false)
        XCTAssertFalse(voice.consentNeeded)
        XCTAssertFalse(AIConsent.given)
        XCTAssertEqual(voice.phase, .idle)
    }

    func testAgreeingRunsWhatWasAskedFor() {
        let voice = VoiceSessionController.shared
        var ran = false
        voice.requestConsent { ran = true }
        voice.answerConsent(true)
        XCTAssertTrue(ran)
        XCTAssertTrue(AIConsent.given)
        XCTAssertFalse(voice.consentNeeded)
    }

    func testDecliningRunsNothing() {
        let voice = VoiceSessionController.shared
        var ran = false
        voice.requestConsent { ran = true }
        voice.answerConsent(false)
        XCTAssertFalse(ran)
    }

    func testReportLinkLeavesTheReplyOut() {
        let url = MessageReport.url.absoluteString
        XCTAssertTrue(url.hasPrefix("https://github.com/kamikaz1k/wake-on/issues/new?"))
        XCTAssertTrue(url.contains("title=Report"))
        XCTAssertFalse(url.contains("\(Agent.name)%20said"), "Only the template goes in the link")
    }
}
