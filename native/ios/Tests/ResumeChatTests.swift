import XCTest
@testable import WakeOn

/// Resuming a chat: the thread of linked logs, the transcript a resumed call carries, and
/// which hang-ups keep a browser chat paused.
final class ResumeChatTests: XCTestCase {
    private func chat(_ lines: [(String, String)], id: UUID = UUID(), resumes: UUID? = nil) -> ChatLog {
        ChatLog(id: id, started: Date(), ended: Date(), trigger: "in_app",
                lines: lines.map { ChatLog.Line(speaker: $0.0, text: $0.1) }, resumes: resumes)
    }

    func testThreadFollowsResumedLogsOldestFirst() {
        let a = chat([("You", "one")]), b = chat([("You", "two")], resumes: a.id), c = chat([("You", "three")], resumes: b.id)
        let thread = ChatLogStore.thread(endingWith: c, in: [c, b, a])
        XCTAssertEqual(thread.map(\.id), [a.id, b.id, c.id])
        // A deleted middle part ends the chain there; a loop can't hang it.
        XCTAssertEqual(ChatLogStore.thread(endingWith: c, in: [c, a]).map(\.id), [c.id])
        let x = UUID(), y = UUID()
        let loopX = chat([("You", "x")], id: x, resumes: y), loopY = chat([("You", "y")], id: y, resumes: x)
        XCTAssertEqual(ChatLogStore.thread(endingWith: loopX, in: [loopX, loopY]).count, 2)
    }

    func testOldSavedLogsStillLoad() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","started":0,"ended":1,"trigger":"in_app","lines":[{"speaker":"You","text":"hi"}]}]"#
        let logs = try JSONDecoder().decode([ChatLog].self, from: Data(json.utf8))
        XCTAssertNil(logs.first?.resumes)
        XCTAssertEqual(chat([("You", "hi")], resumes: UUID()).source, "In app")
    }

    func testHistoryNoteKeepsTheNewestLines() throws {
        XCTAssertNil(LiveVoiceConfig.historyNote([]))
        let short = try XCTUnwrap(LiveVoiceConfig.historyNote([.init(speaker: "You", text: "code word pineapple"),
                                                               .init(speaker: "Lobby", text: "Okay.")]))
        XCTAssertTrue(short.contains("User: code word pineapple\nLobby: Okay."))
        XCTAssertFalse(short.contains("left out"))
        let long = (0..<400).map { ChatLog.Line(speaker: "You", text: "line \($0) " + String(repeating: "x", count: 40)) }
        let note = try XCTUnwrap(LiveVoiceConfig.historyNote(long))
        XCTAssertTrue(note.contains("left out"))
        XCTAssertTrue(note.contains("line 399 "))
        XCTAssertFalse(note.contains("line 0 "))
        XCTAssertLessThan(ChatTokens.estimate(note), ChatTokens.limit + 150)
    }

    func testResumedCallCarriesHistoryToBothModels() throws {
        var config = LiveVoiceConfig()
        config.history = [.init(speaker: "You", text: "code word pineapple")]
        let session = try XCTUnwrap(config.requestBody(sdp: "v=0")["session"] as? [String: Any])
        XCTAssertTrue((session["instructions"] as? String)?.contains("code word pineapple") == true)
        let responses = (session["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        XCTAssertTrue((responses?["instructions"] as? String)?.contains("code word pineapple") == true)
        // Screen updates resend the backend's instructions: the history must survive them.
        let update = config.screenUpdate(.inView)
        let updated = (((update["session"] as? [String: Any])?["delegation"] as? [String: Any])?["responses"] as? [String: Any])?["instructions"] as? String
        XCTAssertTrue(updated?.contains("code word pineapple") == true)
        XCTAssertFalse(LiveVoiceConfig().backendInstructions().contains("resumes an earlier conversation"))
    }

    func testTokenEstimatesAndWarnings() {
        XCTAssertEqual(ChatTokens.estimate("abcd"), 1)
        XCTAssertEqual(ChatTokens.estimate("abcde"), 2)
        // "User: hi" is 8 characters, 2 tokens.
        XCTAssertEqual(ChatTokens.estimate([.init(speaker: "You", text: "hi")]), 2)
        XCTAssertEqual(ChatTokens.label(850), "~850 tokens")
        XCTAssertEqual(ChatTokens.label(1420), "~1.4k tokens")
        XCTAssertEqual(ChatTokens.level(ChatTokens.warnAt - 1), .ok)
        XCTAssertEqual(ChatTokens.level(ChatTokens.warnAt), .long)
        XCTAssertEqual(ChatTokens.level(ChatTokens.limit + 1), .truncated)
        XCTAssertNil(ChatTokens.warning(100))
        XCTAssertTrue(ChatTokens.warning(1300)?.contains("getting long") == true)
        XCTAssertTrue(ChatTokens.warning(2100)?.contains("keeps only the newest") == true)
    }

    func testLookupTokensComeFromTheBackendUsage() {
        let event: [String: Any] = ["type": "response.event",
                                    "event": ["type": "response.completed",
                                              "response": ["usage": ["input_tokens": 7464, "output_tokens": 11]]]]
        XCTAssertEqual(VoiceSessionController.inputTokens(event), 7464)
        XCTAssertNil(VoiceSessionController.inputTokens(["type": "response.event", "event": ["type": "response.completed"]]))
    }

    func testOnlyPauseAndIdleInTheBrowserKeepTheChat() {
        XCTAssertTrue(VoiceSessionController.pausesThread(reason: "paused", browserOpen: true))
        XCTAssertTrue(VoiceSessionController.pausesThread(reason: "idle", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "goodbye", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "user", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "idle", browserOpen: false))
    }
}
