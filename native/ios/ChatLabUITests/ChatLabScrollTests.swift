import XCTest

/// Real swipes in the simulator, for scroll behaviour the replay can't trigger by code.
/// The app logs the library's scroll offsets to Documents/scroll.log ("-lab-log-scroll").
/// Pick the scenario with TEST_RUNNER_LAB_SCENARIO (default A10) and the page with
/// TEST_RUNNER_LAB_LIBRARY (default exyte).
final class ChatLabScrollTests: XCTestCase {
    func testOverscrollAtTop() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-lab-scenario", env["LAB_SCENARIO"] ?? "A10",
                               "-lab-library", env["LAB_LIBRARY"] ?? "exyte",
                               "-lab-log-scroll", "-lab-scroll-top", env["LAB_SCROLL_TOP"] ?? "3"]
        app.launch()
        sleep(UInt32(env["LAB_WAIT"] ?? "5") ?? 5)

        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        // Fling toward the oldest messages until past the top, then pull past the edge.
        for _ in 0..<3 {
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
        }
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        // Leave it alone: a settled list stops logging offsets.
        sleep(6)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
