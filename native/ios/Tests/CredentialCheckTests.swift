import XCTest
@testable import WakeOn

final class CredentialCheckTests: XCTestCase {
    private let server = URL(string: "https://lobby.example")!

    /// A fake network: answers with this status and body, and records what was asked.
    private final class Fake: @unchecked Sendable {
        var requests: [URLRequest] = []
        let status: Int
        let body: String
        let fail: Bool
        init(_ status: Int = 200, _ body: String = "{}", fail: Bool = false) {
            self.status = status; self.body = body; self.fail = fail
        }
        var send: CredentialCheck.Send {
            { request in
                self.requests.append(request)
                if self.fail { throw URLError(.notConnectedToInternet) }
                return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status,
                                                              httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private func check(_ text: String, _ fake: Fake) async -> CredentialCheck.Outcome {
        await CredentialCheck.check(text, server: server, send: fake.send)
    }

    func testGoodInviteCodeIsCheckedWithTheServer() async {
        let fake = Fake(200, #"{"ok":true,"name":"alex"}"#)
        let outcome = await check("  Alex-1-7K2MQ9XD4R8W ", fake)
        XCTAssertEqual(outcome, .valid("Invite code works. Saved."))
        XCTAssertEqual(fake.requests.first?.url?.absoluteString, "https://lobby.example/v1/check")
        XCTAssertEqual(fake.requests.first?.httpMethod, "POST")
        XCTAssertEqual(fake.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer Alex-1-7K2MQ9XD4R8W")
    }

    func testInviteCodeFailures() async {
        let expired = await check("alex-9-7k2mq9xd4r8w", Fake(401, #"{"error":{"code":"expired_code"}}"#))
        XCTAssertFalse(expired.saves)
        XCTAssertTrue(expired.message.contains("Ask for a new one"))
        let revoked = await check("alex-1-7k2mq9xd4r8w", Fake(401, #"{"error":{"code":"revoked_code"}}"#))
        XCTAssertFalse(revoked.saves)
        let wrong = await check("alex-1-7k2mq9xd4r8x", Fake(401, #"{"error":{"code":"invalid_code"}}"#))
        XCTAssertFalse(wrong.saves)
        XCTAssertTrue(wrong.message.contains("typos"))
    }

    func testTextThatIsNeitherIsRejectedWithoutTheNetwork() async {
        let fake = Fake()
        let outcome = await check("hello there", fake)
        XCTAssertFalse(outcome.saves)
        XCTAssertTrue(outcome.message.contains("sk-"))
        XCTAssertTrue(fake.requests.isEmpty)
        let empty = await check("   ", fake)
        XCTAssertFalse(empty.saves)
    }

    func testOfflineOrServerTroubleStillSavesWithAWarning() async {
        let offline = await check("alex-1-7k2mq9xd4r8w", Fake(fail: true))
        XCTAssertTrue(offline.saves)
        XCTAssertTrue(offline.message.contains("no connection"))
        if case .savedWithWarning = offline {} else { XCTFail("expected a warning") }
        let down = await check("alex-1-7k2mq9xd4r8w", Fake(502, "Bad gateway"))
        XCTAssertTrue(down.saves)
        let keyOffline = await check("sk-proj-abc", Fake(fail: true))
        XCTAssertTrue(keyOffline.saves)
    }

    func testOpenAIKeyOutcomes() async {
        let fake = Fake(200, #"{"data":[]}"#)
        let good = await check("sk-proj-abc", fake)
        XCTAssertEqual(good, .valid("OpenAI accepted the key. Saved."))
        XCTAssertEqual(fake.requests.first?.url, CredentialCheck.openAIModels)
        XCTAssertEqual(fake.requests.first?.httpMethod, "GET")

        let bad = await check("sk-proj-abc", Fake(401, #"{"error":{"code":"invalid_api_key"}}"#))
        XCTAssertFalse(bad.saves)
        XCTAssertTrue(bad.message.contains("didn't accept"))

        let broke = await check("sk-proj-abc", Fake(429, #"{"error":{"code":"insufficient_quota"}}"#))
        XCTAssertTrue(broke.saves)
        XCTAssertTrue(broke.message.contains("out of credit"))

        let restricted = await check("sk-proj-abc", Fake(403, #"{"error":{"message":"Insufficient permissions"}}"#))
        XCTAssertTrue(restricted.saves)
    }
}
