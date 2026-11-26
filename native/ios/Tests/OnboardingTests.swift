import CoreLocation
import XCTest
@testable import WakeOn

/// Invite links fill in a friend's code; onboarding ends with starter prompts.
@MainActor
final class OnboardingTests: XCTestCase {
    func testInviteLinkCode() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "wakeon://invite?code=alex-1-7k2mq9xd4r8w")!), "alex-1-7k2mq9xd4r8w")
        XCTAssertEqual(InviteLink.code(from: URL(string: "wakeon://invite?code=%20alex-1-7k2mq9xd4r8w%20")!), "alex-1-7k2mq9xd4r8w")
        XCTAssertNil(InviteLink.code(from: URL(string: "wakeon://invite")!))
        XCTAssertNil(InviteLink.code(from: URL(string: "wakeon://talk?code=x")!))
        XCTAssertNil(InviteLink.code(from: URL(string: "https://example.com/invite?code=x")!))
    }

    /// Every tool Pixie has gets a starter prompt on the last onboarding page, so a new
    /// capability shows up there.
    func testEveryToolHasAStarterPrompt() {
        var config = LiveVoiceConfig()
        config.alarms = true
        let body = config.requestBody(sdp: "v=0")
        let responses = ((body["session"] as? [String: Any])?["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        let tools = (responses?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String ?? $0["type"] as? String })
        XCTAssertTrue(names.contains("calendar"))
        let covered = Set(Onboarding.starters.flatMap(\.tools)).union(Onboarding.backgroundTools)
        XCTAssertEqual(names.subtracting(covered), [], "Add a starter prompt for each new tool")
        XCTAssertEqual(covered.subtracting(names), [], "A starter names a tool that doesn't exist")
        XCTAssertEqual(Set(Onboarding.starters.map(\.text)).count, Onboarding.starters.count)
    }

    /// Location is offered right after the microphone and before the first call, whose weather
    /// question uses it.
    func testLocationStepFollowsMicrophone() {
        typealias Step = OnboardingView.Step
        XCTAssertEqual(Step.location.rawValue, Step.permission.rawValue + 1)
        XCTAssertEqual(Step.firstCall.rawValue, Step.location.rawValue + 1)
        XCTAssertTrue(Onboarding.prompts.first?.text.contains("where I am") ?? false)
    }

    /// The location page always shows; it asks, says it's on, or points to Settings.
    func testLocationPageState() {
        XCTAssertEqual(CurrentLocation.access(.notDetermined), .ask)
        XCTAssertEqual(CurrentLocation.access(.authorizedWhenInUse), .on)
        XCTAssertEqual(CurrentLocation.access(.authorizedAlways), .on)
        XCTAssertEqual(CurrentLocation.access(.denied), .off)
        XCTAssertEqual(CurrentLocation.access(.restricted), .off)
    }
}
