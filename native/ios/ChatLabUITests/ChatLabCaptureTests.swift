import XCTest

/// Replaying a captured call (the bundled made-up sample, R1): the transcript, the backend's
/// tool calls and the app's own "open Spotify" step all appear as rows.
final class ChatLabCaptureTests: XCTestCase {
    func testSampleCallReplaysToolsAndSpotifyOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "R1", "-lab-library", "plain"]
        app.launch()
        func shows(_ text: String, timeout: TimeInterval = 15) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
                .firstMatch.waitForExistence(timeout: timeout)
        }
        XCTAssertTrue(shows("Play Come Sail Away by Styx."), "your words")
        XCTAssertTrue(shows("One moment."), "Lobby's filler")
        XCTAssertTrue(shows("Web Search · done"), "web search row")
        XCTAssertTrue(shows("Play Spotify · done"), "play_spotify row with our result")
        XCTAssertTrue(shows("Open In Spotify · done"), "the app opening Spotify, as a tool row")
        XCTAssertTrue(shows("ended to play on Spotify"), "why the call ended")
    }
}
