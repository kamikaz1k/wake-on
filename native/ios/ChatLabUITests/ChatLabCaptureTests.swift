import XCTest

/// Replaying a captured call (the bundled made-up Spotify sample, R2; samples sort by file name): the transcript, the backend's
/// tool calls and the app's own "open Spotify" step all appear as rows.
final class ChatLabCaptureTests: XCTestCase {
    func testSampleCallReplaysToolsAndSpotifyOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "R2", "-lab-library", "plain"]
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

    /// The made-up visual sample (R3): show_visual becomes a page in the chat, the call goes
    /// on, and tapping the row opens the page full size.
    func testSampleVisualShowsAndOpensFullSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "R3", "-lab-library", "plain"]
        app.launch()
        let open = app.buttons["chat-visual-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "visual row")
        XCTAssertTrue(app.webViews.staticTexts["Daily high, °C"].waitForExistence(timeout: 10), "page in the preview")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "It's on your screen"))
            .firstMatch.waitForExistence(timeout: 15), "Lobby goes on talking after the visual")
        open.tap()
        let done = app.buttons["chat-visual-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "full-size sheet")
        XCTAssertTrue(app.navigationBars["Paris this week"].exists)
        XCTAssertGreaterThanOrEqual(app.webViews.count, 2, "the page in the sheet as well as the preview")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    /// The made-up place sample (R1): open_map's show mode puts an
    /// embedded map in the chat with a link out to Google Maps; tapping opens it full size.
    func testSamplePlaceShowsMapWithLinkOut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "R1", "-lab-library", "plain"]
        app.launch()
        let open = app.buttons["chat-place-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "map row")
        XCTAssertTrue(app.buttons["chat-place-link"].exists, "Open in Google Maps link")
        open.tap()
        let done = app.buttons["chat-place-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "full-size map")
        XCTAssertTrue(app.navigationBars["Demetres"].exists)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
}
