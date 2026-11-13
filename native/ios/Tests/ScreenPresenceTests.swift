import XCTest
@testable import WakeOn

/// Lobby is told whether the user can see the screen: the backend's instructions get a
/// "Screen:" line mid-call, and the chat log shows when it went out of view.
@MainActor
final class ScreenPresenceTests: XCTestCase {
    func testStartingInstructionsHaveTheGuidanceButNoScreenLine() throws {
        let body = LiveVoiceConfig().requestBody(sdp: "")
        let session = try XCTUnwrap(body["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let instructions = try XCTUnwrap(responses["instructions"] as? String)
        XCTAssertTrue(instructions.contains(ScreenPresence.backendGuidance))
        // A prepared offer is built before the trigger, so it can't know the screen yet.
        XCTAssertFalse(instructions.contains("\nScreen:"))
    }

    func testMidCallUpdateKeepsTheInstructionsAndAddsTheScreenLine() throws {
        let config = LiveVoiceConfig()
        for screen in [ScreenPresence.inView, .away] {
            let update = config.screenUpdate(screen)
            XCTAssertEqual(update["type"] as? String, "session.update")
            let delegation = try XCTUnwrap((update["session"] as? [String: Any])?["delegation"] as? [String: Any])
            XCTAssertEqual(delegation["type"] as? String, "responses")
            let responses = try XCTUnwrap(delegation["responses"] as? [String: Any])
            // Only the instructions change: the model and tools stay as they were.
            XCTAssertEqual(Array(responses.keys), ["instructions"])
            let instructions = try XCTUnwrap(responses["instructions"] as? String)
            XCTAssertEqual(instructions, config.backendInstructions() + "\n" + screen.backendLine)
            XCTAssertTrue(instructions.contains("show_visual") && instructions.contains("open_map"))
        }
    }

    func testChatLogShowsWhenTheScreenWasOutOfView() {
        func line(_ t: Double, _ event: [String: Any]) -> CapturedCall.Line { .init(t: t, source: "app", event: event) }
        func markers(_ states: [String]) -> [String] {
            let lines = [line(0, ["type": "app.call_started", "trigger": "wake_word"])]
                + states.enumerated().map { line(Double($0.offset + 1), ["type": "app.screen", "state": $0.element]) }
            return ChatTranscript(steps: CaptureReplay(lines: lines, rawEvents: false).steps, startedAt: Date()).items
                .compactMap { if case let .marker(text, _) = $0.kind, text.hasPrefix("Screen") { text } else { nil } }
        }
        // The usual start, in view, gets no line; going away and coming back do.
        XCTAssertEqual(markers(["in_view"]), [])
        XCTAssertEqual(markers(["in_view", "away", "in_view"]),
                       ["Screen not in view · Lobby answers in speech", "Screen in view · Lobby can show things"])
        XCTAssertEqual(markers(["away"]), ["Screen not in view · Lobby answers in speech"])
    }
}
