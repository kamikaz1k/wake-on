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
        XCTAssertTrue(short.contains("User: code word pineapple\n\(Agent.name): Okay."))
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

    func testTokenEstimates() {
        XCTAssertEqual(ChatTokens.estimate("abcd"), 1)
        XCTAssertEqual(ChatTokens.estimate("abcde"), 2)
        // "User: hi" is 8 characters, 2 tokens.
        XCTAssertEqual(ChatTokens.estimate([.init(speaker: "You", text: "hi")]), 2)
        XCTAssertEqual(ChatTokens.label(850), "~850 tokens")
        XCTAssertEqual(ChatTokens.label(1420), "~1.4k tokens")
    }

    func testLookupTokensComeFromTheBackendUsage() {
        let event: [String: Any] = ["type": "response.event",
                                    "event": ["type": "response.completed",
                                              "response": ["usage": ["input_tokens": 7464, "output_tokens": 11]]]]
        XCTAssertEqual(VoiceSessionController.inputTokens(event), 7464)
        XCTAssertNil(VoiceSessionController.inputTokens(["type": "response.event", "event": ["type": "response.completed"]]))
    }

    func testErrorsAfterHangingUpAreNotShown() {
        let early = "The session closed before the estimated context injection completed."
        XCTAssertNil(VoiceSessionController.userFacingError(early, hangingUp: true))
        XCTAssertNil(VoiceSessionController.userFacingError("Anything", hangingUp: true))
        // If the server closes it by itself: a plain explanation instead of the raw message.
        XCTAssertEqual(VoiceSessionController.userFacingError(early, hangingUp: false),
                       "\(Agent.name) was still getting ready when the call ended. Try again.")
        XCTAssertEqual(VoiceSessionController.userFacingError("Invalid API key", hangingUp: false), "Invalid API key")
    }

    /// The transcript (live and saved) leaves out the error once the app has asked to close;
    /// it used to show the raw "context injection" message in red.
    @MainActor func testTranscriptHidesErrorsAfterClose() throws {
        func replay(_ lines: [String]) throws -> [ChatItem] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            let call = try XCTUnwrap(CapturedCall.load(url))
            let transcript = ChatTranscript(steps: CaptureReplay(lines: call.lines, rawEvents: false).steps, startedAt: Date())
            return transcript.items
        }
        let error = #"{"t_ms": 1600, "source": "server", "event": {"type": "error", "error": {"message": "The session closed before the estimated context injection completed."}}}"#
        let start = [#"{"t_ms": 0, "source": "app", "event": {"type": "app.call_started"}}"#,
                     #"{"t_ms": 900, "source": "server", "event": {"type": "session.started"}}"#]
        let close = #"{"t_ms": 1500, "source": "client", "event": {"type": "session.close"}}"#
        let afterClose = try replay(start + [close, error]).map(\.text)
        XCTAssertFalse(afterClose.contains { $0.contains("context injection") || $0.contains("getting ready") })
        let serverClosed = try replay(start + [error]).map(\.text)
        XCTAssertTrue(serverClosed.contains("\(Agent.name) was still getting ready when the call ended. Try again."))
    }

    func testOnlyPauseAndIdleInTheBrowserKeepTheChat() {
        XCTAssertTrue(VoiceSessionController.pausesThread(reason: "paused", browserOpen: true))
        XCTAssertTrue(VoiceSessionController.pausesThread(reason: "idle", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "goodbye", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "user", browserOpen: true))
        XCTAssertFalse(VoiceSessionController.pausesThread(reason: "idle", browserOpen: false))
    }
}
