import XCTest
@testable import WakeOn

/// The tool chain: how a turn's tool calls group, when a chain collapses, and its words.
final class ChatToolChainTests: XCTestCase {
    private func tool(_ name: String, _ state: ChatItem.ToolState, args: String = "") -> ChatItem.Tool {
        ChatItem.Tool(name: name, arguments: args, result: nil, state: state)
    }
    private func item(_ id: String, _ kind: ChatItem.Kind) -> ChatItem { ChatItem(id: id, kind: kind) }

    func testConsecutiveToolsBecomeOneChain() {
        let items = [item("u", .message(.user, text: "play", state: .done)),
                     item("t1", .tool(tool("web_search", .done))),
                     item("t2", .tool(tool("play_spotify", .done))),
                     item("l", .message(.lobby, text: "Here it is", state: .done))]
        let segments = ChatToolGrouping.segments(items, live: true)
        XCTAssertEqual(segments.map(\.id), ["u", "chain-t1", "l"])
        guard case let .tools(tools, finished) = segments[1].content else { return XCTFail() }
        XCTAssertEqual(tools.map(\.name), ["web_search", "play_spotify"])
        XCTAssertTrue(finished, "Lobby replied after it, so it collapses")
    }

    func testRunningOrTrailingChainStaysOpenWhileLive() {
        let running = [item("t1", .tool(tool("web_search", .running)))]
        XCTAssertTrue(ChatToolGrouping.endsWithRunningChain(ChatToolGrouping.segments(running, live: true)))
        // Done, but nothing after it yet in a live turn: still open.
        let done = [item("t1", .tool(tool("web_search", .done)))]
        XCTAssertTrue(ChatToolGrouping.endsWithRunningChain(ChatToolGrouping.segments(done, live: true)))
        // A saved call: collapsed.
        XCTAssertFalse(ChatToolGrouping.endsWithRunningChain(ChatToolGrouping.segments(done, live: false)))
    }

    func testVisualsAndMapsAreNotChained() {
        var visual = tool("show_visual", .done)
        visual.visual = .init(title: "Chart", html: "<p>", complete: true)
        let items = [item("t1", .tool(tool("web_search", .done))), item("v", .tool(visual))]
        XCTAssertEqual(ChatToolGrouping.segments(items, live: false).map(\.id), ["chain-t1", "v"])
    }

    func testStepWords() {
        XCTAssertEqual(ChatToolSteps.label(tool("web_search", .running)), "Searching the web")
        XCTAssertEqual(ChatToolSteps.label(tool("web_search", .done, args: #"{"query":"weather"}"#)), "Searched “weather”")
        XCTAssertEqual(ChatToolSteps.label(tool("browser", .running, args: #"{"action":"find","text":"deck"}"#)), "Finding “deck”")
        XCTAssertEqual(ChatToolSteps.label(tool("open_in_spotify", .done, args: "Come Sail Away\nspotify:x")),
                       "Opened Come Sail Away in Spotify")
        XCTAssertEqual(ChatToolSteps.label(tool("play_youtube", .failed, args: #"{"title":"Rick"}"#)), "Picked Rick (failed)")
    }

    func testSummaryNamesEachKindOnce() {
        let tools = [tool("web_search", .done), tool("play_spotify", .done), tool("open_in_spotify", .done)]
        XCTAssertEqual(ChatToolSteps.summary(tools), "Searched the web, opened Spotify")
        let many = tools + [tool("browser", .done), tool("open_map", .done)]
        XCTAssertEqual(ChatToolSteps.summary(many), "Searched the web, opened Spotify and 2 more")
    }
}
