import XCTest
@testable import WakeOn

/// Pixie's send_feedback tool: offered with its instructions, trims what it sends, and only
/// sends with an invite code (an OpenAI key keeps it on the iPhone).
@MainActor
final class FeedbackTests: XCTestCase {
    func testToolIsOfferedWithInstructions() throws {
        let responses = try responses(LiveVoiceConfig())
        let names = (responses["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("send_feedback"))
        XCTAssertTrue((responses["instructions"] as? String)?.contains("call send_feedback") == true)

        var config = LiveVoiceConfig()
        config.feedback = false
        let without = try self.responses(config)
        XCTAssertFalse(((without["tools"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "send_feedback" })
        XCTAssertFalse((without["instructions"] as? String)?.contains("send_feedback") == true)
    }

    func testBodyIsTrimmedAndCarriesTheBuild() {
        let body = Feedback.body(feedback: "  The map opened the wrong place \n", context: " Asked for a hotpot place ", app: "1.0 (7)")
        XCTAssertEqual(body["feedback"] as? String, "The map opened the wrong place")
        XCTAssertEqual(body["context"] as? String, "Asked for a hotpot place")
        XCTAssertEqual(body["app"] as? String, "1.0 (7)")
    }

    func testEmptyFeedbackIsNotSent() async {
        let result = await Feedback.send(feedback: "   ", context: "", credential: nil, server: nil)
        XCTAssertEqual(result, Feedback.emptyText)
    }

    func testAnOpenAIKeyKeepsItOnThePhone() async {
        let result = await Feedback.send(feedback: "Love it", context: "", credential: "sk-test", server: nil)
        XCTAssertEqual(result, Feedback.keptText)
    }

    private func responses(_ config: LiveVoiceConfig) throws -> [String: Any] {
        let session = try XCTUnwrap(config.requestBody(sdp: "v=0")["session"] as? [String: Any])
        return try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
    }
}
