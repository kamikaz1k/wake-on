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

final class AssistantNameTests: XCTestCase {
    override func tearDown() { UserDefaults.standard.removeObject(forKey: LiveVoiceConfig.nameKey) }

    func testDefaultNameLeavesInstructionsAlone() {
        let original = LiveVoiceConfig().instructions
        XCTAssertEqual(LiveVoiceConfig.named(original, "Lobby"), original)
    }

    func testCustomNameReplacesTheIntroduction() {
        let named = LiveVoiceConfig.named(LiveVoiceConfig().instructions, "Juno")
        XCTAssertTrue(named.hasPrefix("You are Juno, a voice assistant"))
        XCTAssertFalse(named.contains("You are Lobby"))
    }

    func testBlankNameFallsBack() {
        UserDefaults.standard.set("   ", forKey: LiveVoiceConfig.nameKey)
        XCTAssertEqual(LiveVoiceConfig.assistantName, "Lobby")
        UserDefaults.standard.set(" Juno ", forKey: LiveVoiceConfig.nameKey)
        XCTAssertEqual(LiveVoiceConfig.assistantName, "Juno")
    }
}
