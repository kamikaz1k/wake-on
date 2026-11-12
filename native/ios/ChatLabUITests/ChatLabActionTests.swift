import XCTest

/// The copy action under a finished message on our page.
final class ChatLabActionTests: XCTestCase {
    func testCopyShowsConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", "F3", "-lab-library", "plain"]
        app.launch()
        let copy = app.buttons.matching(identifier: "message-copy").firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "copy button under messages")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2), "confirms the copy")
    }
}
