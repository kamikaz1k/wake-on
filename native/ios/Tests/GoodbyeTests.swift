import XCTest
@testable import WakeOn

/// After Lobby says bye, room noise must not hold the call open (it once took 18 s).
final class GoodbyeTests: XCTestCase {
    private let wait = VoiceSessionController.endSilenceSeconds

    func testHangsUpTwoSecondsAfterLobbyStopsWhateverTheMicHears() {
        // Mic level isn't an input at all: only Lobby's audio and the user's words count.
        XCTAssertFalse(VoiceSessionController.goodbyeHangsUp(now: 10 + wait - 0.1, lobbyLastActive: 10, userLastWords: nil, lookingUp: false))
        XCTAssertTrue(VoiceSessionController.goodbyeHangsUp(now: 10 + wait, lobbyLastActive: 10, userLastWords: nil, lookingUp: false))
    }

    func testUserWordsDelayTheHangUp() {
        XCTAssertFalse(VoiceSessionController.goodbyeHangsUp(now: 13, lobbyLastActive: 10, userLastWords: 12, lookingUp: false))
        XCTAssertTrue(VoiceSessionController.goodbyeHangsUp(now: 14.5, lobbyLastActive: 10, userLastWords: 12, lookingUp: false))
        // Words from before the goodbye don't matter.
        XCTAssertTrue(VoiceSessionController.goodbyeHangsUp(now: 12, lobbyLastActive: 10, userLastWords: 5, lookingUp: false))
    }

    func testWaitsForALookupInProgress() {
        XCTAssertFalse(VoiceSessionController.goodbyeHangsUp(now: 20, lobbyLastActive: 10, userLastWords: nil, lookingUp: true))
    }

    func testByeDetection() {
        XCTAssertTrue(VoiceSessionController.endsWithBye("You’re welcome, bye."))
        XCTAssertTrue(VoiceSessionController.endsWithBye("Okay, bye!"))
        XCTAssertFalse(VoiceSessionController.endsWithBye("Bye now, but first: anything else?"))
    }
}
