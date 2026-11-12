import XCTest

/// Switching libraries away and back must not leave a page blank (the pager can recreate a
/// page; our SwiftUI page used to stay hidden until new messages arrived).
final class ChatLabPagingTests: XCTestCase {
    func testOurPageShowsMessagesAfterSwitchingBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "F3", "-lab-library", "plain"]
        app.launch()
        let message = app.staticTexts["Remind me what we talked about yesterday."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "messages shown at first")

        for _ in 0..<3 { app.buttons["lab-next"].tap(); sleep(1) }
        for _ in 0..<3 { app.buttons["lab-previous"].tap(); sleep(1) }

        XCTAssertTrue(message.waitForExistence(timeout: 3), "messages shown after switching back")
        XCTAssertTrue(message.isHittable, "messages visible, not hidden")
    }
}
