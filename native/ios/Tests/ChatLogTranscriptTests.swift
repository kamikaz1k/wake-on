import XCTest
@testable import WakeOn

/// The chat log page builds Lobby's chat view from a call's capture, or from its lines for
/// calls saved before captures.
@MainActor
final class ChatLogTranscriptTests: XCTestCase {
    private var base: URL!
    override func setUp() { base = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func log(id: UUID = UUID()) -> ChatLog {
        ChatLog(id: id, started: Date(timeIntervalSince1970: 1_000_000), ended: Date(timeIntervalSince1970: 1_000_017),
                trigger: "app_intent_fast", lines: [.init(speaker: "You", text: "Play Ocean Avenue"), .init(speaker: "Lobby", text: "One moment.")])
    }

    func testCaptureShowsMessagesToolsAndSpotifyWithRealTimes() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("chat view needs iOS 18") }
        let capture = CallCapture(origin: 0)
        capture.app("call_started", ["trigger": "app_intent_fast"], at: 0)
        capture.record(.server, ["type": "session.started"], at: 900_000_000)
        capture.record(.server, ["type": "session.input_transcript.delta", "delta": " Play Ocean Avenue"], at: 2_000_000_000)
        capture.record(.server, ["type": "session.output_transcript.delta", "delta": " One moment."], at: 3_000_000_000)
        capture.record(.server, ["type": "response.event", "delegation_id": "d1",
                                 "event": ["type": "response.output_item.added", "item": ["type": "function_call", "id": "fc_1", "name": "play_spotify", "call_id": "c1"]]],
                       at: 4_000_000_000)
        capture.app("tool_call", ["call_id": "c1", "output": "Opening Ocean Avenue in Spotify"], at: 4_100_000_000)
        capture.app("call_ended", ["reason": "close_requested", "spotify_pending": true], at: 5_000_000_000)
        capture.app("spotify_open", ["title": "Ocean Avenue", "app_url": "spotify:track:x", "web_url": "https://open.spotify.com/track/x"], at: 5_100_000_000)
        capture.app("spotify_opened", ["outcome": "universal_link"], at: 5_200_000_000)
        let store = ChatLogStore(url: base.appendingPathComponent("logs.json"), capturesFolder: base.appendingPathComponent("captures"))
        let log = log(id: capture.id)
        store.add(log, capture: capture)

        let items = ChatLogTranscript.transcript(for: log, capture: store.captureURL(for: log.id)).items
        let messages = items.compactMap { item -> String? in if case let .message(_, text, .done) = item.kind { text } else { nil } }
        XCTAssertEqual(messages, ["Play Ocean Avenue", "One moment."])
        let tools = items.compactMap { item -> ChatItem.Tool? in if case let .tool(tool) = item.kind { tool } else { nil } }
        XCTAssertEqual(tools.map(\.name), ["play_spotify", "open_in_spotify"])
        XCTAssertEqual(tools.map(\.state), [.done, .done])
        XCTAssertEqual(tools.last?.sources.first?.url, "https://open.spotify.com/track/x")
        // Rows carry when they happened in the call, not when the page opened.
        XCTAssertEqual(items.first { $0.isUser }?.time, log.started.addingTimeInterval(2))
    }

    func testOlderLogsShowTheirLines() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("chat view needs iOS 18") }
        let items = ChatLogTranscript.transcript(for: log(), capture: nil).items
        XCTAssertEqual(items.map(\.text), ["Action Button · 0:17", "Play Ocean Avenue", "One moment."])
        XCTAssertEqual(items.map(\.speaker), [nil, .user, .lobby])
    }
}
