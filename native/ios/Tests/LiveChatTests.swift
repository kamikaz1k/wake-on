import XCTest
@testable import WakeOn

/// The live call screen and the chat log afterwards must show the same rows for a call.
@MainActor
final class LiveChatTests: XCTestCase {
    private func lines() -> [CapturedCall.Line] {
        func line(_ t: Double, _ source: String, _ event: [String: Any]) -> CapturedCall.Line {
            CapturedCall.Line(t: t, source: source, event: event)
        }
        return [
            line(0, "app", ["type": "app.call_started", "trigger": "wake_word"]),
            line(0.9, "server", ["type": "session.started"]),
            line(1.5, "server", ["type": "session.input_transcript.delta", "delta": " What's the weather"]),
            line(1.9, "server", ["type": "session.input_transcript.delta", "delta": " in Paris?"]),
            line(2.3, "server", ["type": "session.delegation.created"]),
            line(2.5, "server", ["type": "session.output_transcript.delta", "delta": " One moment."]),
            line(2.6, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.added", "item": ["type": "web_search_call", "id": "ws"]]]),
            line(3.5, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.done", "item": ["type": "web_search_call", "id": "ws", "action": ["query": "Paris weather"]]]]),
            line(3.6, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.completed"]]),
            line(4.0, "server", ["type": "session.output_transcript.delta", "delta": " It's 12 degrees"]),
            line(4.4, "server", ["type": "session.output_transcript.delta", "delta": " and cloudy."]),
            line(6.0, "server", ["type": "session.closed"]),
            line(6.1, "app", ["type": "app.call_ended", "reason": "close_requested"]),
        ]
    }

    func testLiveChatMatchesTheSavedReplay() {
        let live = LiveChat()
        var midCall: [ChatItem] = []
        for line in lines() {
            live.add(line)
            if line.t == 2.6 { midCall = live.transcript.items }
        }
        let saved = ChatTranscript(steps: CaptureReplay(lines: lines(), rawEvents: false).steps, startedAt: Date()).items
        XCTAssertEqual(live.transcript.items.map(\.kind), saved.map(\.kind))
        XCTAssertEqual(live.transcript.items.map(\.timing), saved.map(\.timing))
        // While it happens, Lobby's filler is still streaming and the search is under way.
        XCTAssertTrue(midCall.contains { $0.kind == .message(.lobby, text: "One moment.", state: .streaming) })
        XCTAssertTrue(midCall.contains { if case let .tool(tool) = $0.kind { tool.state == .requested } else { false } })
        let messages = saved.compactMap { item -> String? in if case let .message(_, text, _) = item.kind { text } else { nil } }
        XCTAssertEqual(messages, ["What's the weather in Paris?", "One moment.", "It's 12 degrees and cloudy."])
    }
}
