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

    /// A server that's down, slow or erroring must never crash the call: the tool says so and
    /// the copy on the iPhone is kept.
    func testAFailedSendIsReportedNotFatal() async {
        let code = "test-invite-code"
        let down = URL(string: "http://127.0.0.1:9")!
        let result = await Feedback.send(feedback: "It kept cutting out", context: "", credential: code, server: down,
                                         warnings: ["Weak call connection", "Network: wifi"])
        XCTAssertEqual(result, Feedback.failedText)
    }

    private func responses(_ config: LiveVoiceConfig) throws -> [String: Any] {
        let session = try XCTUnwrap(config.requestBody(sdp: "v=0")["session"] as? [String: Any])
        return try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
    }

    /// Settings and feedback name the build, with its commit when the build script set one.
    func testAppBuildNamesVersionNumberAndCommit() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202611261831",
                                   "PixieCommit": "4696310"]
        XCTAssertTrue(AppBuild.text(info: info).hasPrefix("0.1.0 (202611261831) · 4696310"))
        // Built from Xcode: the setting is empty, so no commit and no stray separator.
        var plain = info
        plain["PixieCommit"] = ""
        XCTAssertFalse(AppBuild.text(info: plain).contains("·  "))
        XCTAssertTrue(AppBuild.text(info: plain).hasPrefix("0.1.0 (202611261831)"))
        XCTAssertFalse(AppBuild.text(info: plain).contains("4696310"))
        XCTAssertEqual(Feedback.build, AppBuild.text)
    }

    /// Every request to the server says which build sent it, so we know who is on what.
    func testServerRequestsCarryTheBuildAndOpenAIRequestsDont() throws {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202611271426",
                                   "PixieCommit": "fae64eb"]
        let header = AppBuild.header(info: info)
        XCTAssertTrue(header.hasPrefix("0.1.0 (202611271426) fae64eb"))
        XCTAssertTrue(header.allSatisfy(\.isASCII), header)

        var server = URLRequest(url: URL(string: "https://example.com/v1/usage")!)
        LobbyServer.authorize(&server, credential: "alex-2-abcdefghijkl", build: header)
        XCTAssertEqual(server.value(forHTTPHeaderField: "Authorization"), "Bearer alex-2-abcdefghijkl")
        XCTAssertEqual(server.value(forHTTPHeaderField: LobbyServer.buildHeader), header)

        var openAI = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        LobbyServer.authorize(&openAI, credential: "sk-test", build: header)
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(openAI.value(forHTTPHeaderField: LobbyServer.buildHeader))

        // No request signs itself by hand, so none can skip the header.
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WakeOn")
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift")
            && file != "LobbyServer.swift" {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("forHTTPHeaderField: \"Authorization\""), file)
        }
    }
}
