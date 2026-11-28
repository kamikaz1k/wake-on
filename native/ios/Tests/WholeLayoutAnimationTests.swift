import XCTest

/// Expanding, collapsing and banners animate the whole layout, not just themselves. Each case
/// below jumped its neighbours in one frame on video before (2026-11-27): a scoped
/// `.animation(_:value:)` on the changing view, or a state change outside `withAnimation`.
final class WholeLayoutAnimationTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
    }

    /// Tool step details: rows below jumped ~370 pt in one frame.
    func testToolStepDetailsToggleInsideWithAnimation() throws {
        let chain = try source("ChatUI/ChatToolChain.swift")
        XCTAssertTrue(chain.contains("withAnimation(ChatToolChain.motion) { details.toggle() }"))
        XCTAssertFalse(chain.contains("Button { details.toggle() }"))
    }

    /// Call screen: the transcript jumped 36 pt as the connection banner came and went.
    func testConnectionBannerAnimatesTheCallScreen() throws {
        let home = try source("WakeOn/HomeView.swift")
        XCTAssertFalse(home.contains("ConnectionBanner(state: voice.connection)\n                .animation"),
                       "Animate voice.connection on the call screen's stack, not on the banner")
        XCTAssertTrue(home.contains(".animation(.easeInOut(duration: 0.25), value: voice.connection)"))
    }

    /// Home: the orb jumped 40-54 pt as "No internet connection" came and went.
    func testNetworkBannerAnimatesTheWholeHomeScreen() throws {
        let home = try source("WakeOn/HomeView.swift")
        let banner = try XCTUnwrap(home.components(separatedBy: "struct NetworkStatusBanner").last?
            .components(separatedBy: "struct NetworkStatusBadge").first)
        XCTAssertNil(banner.range(of: #"\.animation\((?!_:)"#, options: .regularExpression),
                     "The banner's own changes go in withAnimation; network changes animate on Home")
        XCTAssertTrue(home.contains(".animation(.easeInOut(duration: 0.35), value: network.isUp)"))
    }

    /// Onboarding: later sub-steps jumped 40-170 pt in one frame.
    func testOnboardingSubstepsAnimateTheWholePage() throws {
        let onboarding = try source("WakeOn/Onboarding.swift")
        let substep = try XCTUnwrap(onboarding.components(separatedBy: "struct OnboardingSubstep").last?
            .components(separatedBy: "/// A call in progress").first)
        XCTAssertNil(substep.range(of: #"\.animation\((?!_:)"#, options: .regularExpression))
        // Every change after the start goes through setHeySub (withAnimation).
        let bare = onboarding.components(separatedBy: "heySub = ").count - 1
        XCTAssertEqual(bare, 3, "Only the declaration, the reset and setHeySub assign heySub directly")
    }
}
