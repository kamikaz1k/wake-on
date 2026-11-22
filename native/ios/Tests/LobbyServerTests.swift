import XCTest
@testable import WakeOn

final class LobbyServerTests: XCTestCase {
    private let openAI = URL(string: "https://api.openai.com/v1/live/sessions")!
    private let server = URL(string: "https://wake-on.example.workers.dev")!

    func testKeysGoToOpenAIAndCodesToTheServer() throws {
        XCTAssertEqual(try LobbyServer.endpoint(for: "sk-proj-abc", openAI: openAI, server: server), openAI)
        XCTAssertEqual(try LobbyServer.endpoint(for: "ab12-cd34-ef56", openAI: openAI, server: server).absoluteString,
                       "https://wake-on.example.workers.dev/v1/live/sessions")
    }

    func testCodeWithoutAServerSaysSo() {
        XCTAssertThrowsError(try LobbyServer.endpoint(for: "ab12-cd34-ef56", openAI: openAI, server: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("no Lobby server"))
        }
        XCTAssertNoThrow(try LobbyServer.endpoint(for: "sk-abc", openAI: openAI, server: nil))
    }

    func testCodeProblemsSayWhatToDo() {
        for code in ["expired_code", "revoked_code"] {
            let problem = LobbyServer.problem(status: 401, code: code)
            XCTAssertEqual(problem?.needsNewCode, true)
            XCTAssertTrue(problem?.message.contains("Ask for a new one") == true)
        }
        XCTAssertEqual(LobbyServer.problem(status: 401, code: "invalid_code")?.needsNewCode, true)
        // OpenAI refusing the server's own key isn't the friend's code.
        let serverKey = LobbyServer.problem(status: 401, code: "invalid_api_key")
        XCTAssertEqual(serverKey?.needsNewCode, false)
        XCTAssertTrue(serverKey?.message.contains("Try again later") == true)
        XCTAssertNil(LobbyServer.problem(status: 400, code: "invalid_value"))
    }

    func testDailyLimitSaysWhenCallsComeBack() throws {
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        toronto.locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T15:00:00Z"))
        let problem = LobbyServer.problem(status: 429, code: "daily_limit", now: now, calendar: toronto)
        XCTAssertEqual(problem?.needsNewCode, false)
        XCTAssertEqual(problem?.message, "You've used today's calls. More at 7:00\u{202F}PM.")
    }
}
