import XCTest
@testable import WakeOn

final class UsageReportTests: XCTestCase {
    func testBackendTokensAreReadAndSummed() {
        let event: [String: Any] = ["event": ["type": "response.completed", "response": ["usage": [
            "input_tokens": 1200, "input_tokens_details": ["cached_tokens": 1000], "output_tokens": 80]]]]
        var total = UsageReport.Tokens()
        total.add(UsageReport.Tokens(event)!)
        total.add(UsageReport.Tokens(event)!)
        XCTAssertEqual(total, UsageReport.Tokens(input: 2400, cached: 2000, output: 160))
        XCTAssertNil(UsageReport.Tokens(["event": ["response": [:]]]))
    }

    func testBodyRoundsSecondsAndCarriesTokens() {
        let body = UsageReport.body(seconds: 63.27, tokens: UsageReport.Tokens(input: 10, cached: 4, output: 2))
        XCTAssertEqual(body["seconds"] as? Double, 63.3)
        XCTAssertEqual(body["input_tokens"] as? Int, 10)
        XCTAssertEqual(body["cached_tokens"] as? Int, 4)
        XCTAssertEqual(body["output_tokens"] as? Int, 2)
    }
}
