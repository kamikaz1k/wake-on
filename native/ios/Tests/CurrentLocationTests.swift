import XCTest
@testable import WakeOn

final class CurrentLocationTests: XCTestCase {
    func testResultNamesThePlaceAndRoundsCoordinates() {
        let place = CurrentLocation.Place(latitude: 43.70712, longitude: -79.39834, accuracy: 35,
                                          name: "Yonge and Eglinton, Toronto, Ontario, Canada", approximate: false)
        let text = CurrentLocation.resultText(place)
        XCTAssertTrue(text.contains("Yonge and Eglinton, Toronto"))
        XCTAssertTrue(text.contains("(43.707, -79.398;"))
        XCTAssertTrue(text.contains("within about 100 m"))
        XCTAssertFalse(text.contains("43.7071"))
    }

    func testApproximateLocationSaysOnlyTheTownIsKnown() {
        let place = CurrentLocation.Place(latitude: 43.7, longitude: -79.4, accuracy: 3_000, name: "Toronto, Ontario, Canada", approximate: true)
        XCTAssertTrue(CurrentLocation.resultText(place).contains("approximate"))
    }

    func testNameSkipsBlanksAndRepeats() {
        XCTAssertEqual(CurrentLocation.name(subLocality: nil, locality: "Toronto", area: "ON", country: "Canada"), "Toronto, ON, Canada")
        XCTAssertEqual(CurrentLocation.name(subLocality: "Singapore", locality: "Singapore", area: " ", country: "Singapore"), "Singapore")
    }

    /// The backend gets the tool and is told when to use it; turning it off removes both.
    func testToolIsOfferedToTheBackend() {
        var config = LiveVoiceConfig()
        XCTAssertTrue(tools(config).contains(CurrentLocation.toolName))
        XCTAssertTrue(config.backendInstructions().contains("call get_location first"))
        config.location = false
        XCTAssertFalse(tools(config).contains(CurrentLocation.toolName))
        XCTAssertFalse(config.backendInstructions().contains("get_location"))
    }

    private func tools(_ config: LiveVoiceConfig) -> [String] {
        let session = config.requestBody(sdp: "")["session"] as? [String: Any]
        let responses = (session?["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        return (responses?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}
