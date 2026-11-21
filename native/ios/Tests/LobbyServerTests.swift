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
}
