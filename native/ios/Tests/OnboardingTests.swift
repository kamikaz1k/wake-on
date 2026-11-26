import XCTest
@testable import WakeOn

/// Invite links fill in a friend's code; onboarding's demo has recorded calls to play.
@MainActor
final class OnboardingTests: XCTestCase {
    func testInviteLinkCode() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "wakeon://invite?code=alex-1-7k2mq9xd4r8w")!), "alex-1-7k2mq9xd4r8w")
        XCTAssertEqual(InviteLink.code(from: URL(string: "wakeon://invite?code=%20alex-1-7k2mq9xd4r8w%20")!), "alex-1-7k2mq9xd4r8w")
        XCTAssertNil(InviteLink.code(from: URL(string: "wakeon://invite")!))
        XCTAssertNil(InviteLink.code(from: URL(string: "wakeon://talk?code=x")!))
        XCTAssertNil(InviteLink.code(from: URL(string: "https://example.com/invite?code=x")!))
    }

    func testDemoCallsAreBundled() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: nil) ?? []
        let calls = urls.compactMap(CapturedCall.load)
        XCTAssertGreaterThanOrEqual(calls.count, 3, "The onboarding demo replays the sample calls")
        XCTAssertTrue(calls.allSatisfy { !CaptureReplay(lines: $0.lines, rawEvents: false).steps.isEmpty })
    }

    /// Location is offered right after the microphone and before the first call, whose weather
    /// question uses it.
    func testLocationStepFollowsMicrophone() {
        typealias Step = OnboardingView.Step
        XCTAssertEqual(Step.location.rawValue, Step.permission.rawValue + 1)
        XCTAssertEqual(Step.firstCall.rawValue, Step.location.rawValue + 1)
        XCTAssertTrue(Onboarding.prompts.first?.text.contains("where I am") ?? false)
    }
}
