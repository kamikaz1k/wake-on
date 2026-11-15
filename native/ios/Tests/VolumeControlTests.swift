import XCTest
@testable import WakeOn

final class VolumeControlTests: XCTestCase {
    private func target(_ change: String, _ level: Int, from current: Float) -> Float? {
        VolumeControl.request(change: change, level: level).map { VolumeControl.target($0, current: current) }
    }

    func testSetUpAndDown() throws {
        XCTAssertEqual(try XCTUnwrap(target("set", 30, from: 0.8)), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(target("set", 0, from: 0.8)), 0, accuracy: 0.001, "mute")
        XCTAssertEqual(try XCTUnwrap(target("up", 0, from: 0.5)), 0.65, accuracy: 0.001, "a normal step")
        XCTAssertEqual(try XCTUnwrap(target("down", 20, from: 0.5)), 0.3, accuracy: 0.001)
        // Clamped to 0–1.
        XCTAssertEqual(try XCTUnwrap(target("up", 50, from: 0.9)), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(target("down", 0, from: 0.05)), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(target("set", 250, from: 0.5)), 1, accuracy: 0.001)
        XCTAssertNil(target("louder", 10, from: 0.5))
    }

    func testDescriptionsForLobby() {
        XCTAssertEqual(VolumeControl.request(change: "set", level: 30)?.description, "to 30%")
        XCTAssertEqual(VolumeControl.request(change: "up", level: 0)?.description, "up")
        XCTAssertEqual(VolumeControl.request(change: "down", level: 20)?.description, "down by 20%")
    }

    func testOfferedToTheBackend() {
        XCTAssertTrue(LiveVoiceConfig().backendInstructions().contains("set_volume"))
        var config = LiveVoiceConfig()
        config.volume = false
        XCTAssertFalse(config.backendInstructions().contains("set_volume"))
    }
}
