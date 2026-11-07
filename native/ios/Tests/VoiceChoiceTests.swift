import XCTest
@testable import WakeOn

final class VoiceChoiceTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: LiveVoiceConfig.voiceKey) }

    func testDefaultAndSavedVoice() {
        UserDefaults.standard.removeObject(forKey: LiveVoiceConfig.voiceKey)
        XCTAssertEqual(LiveVoiceConfig.chosenVoice, "marin")
        UserDefaults.standard.set("cedar", forKey: LiveVoiceConfig.voiceKey)
        XCTAssertEqual(LiveVoiceConfig.chosenVoice, "cedar")
    }

    /// An unknown name would make OpenAI reject the session, so it falls back to marin.
    func testUnknownVoiceFallsBack() {
        UserDefaults.standard.set("robot", forKey: LiveVoiceConfig.voiceKey)
        XCTAssertEqual(LiveVoiceConfig.chosenVoice, "marin")
    }

    func testRequestUsesTheVoice() {
        var config = LiveVoiceConfig()
        config.voice = "sage"
        let audio = (config.requestBody(sdp: "v=0")["session"] as? [String: Any])?["audio"] as? [String: Any]
        XCTAssertEqual((audio?["output"] as? [String: Any])?["voice"] as? String, "sage")
    }
}

