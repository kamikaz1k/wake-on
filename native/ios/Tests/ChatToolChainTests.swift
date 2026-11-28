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
        XCTAssertTrue(finished, "\(Agent.name) replied after it, so it collapses")
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

    /// Chat Lab's exyte and ConversationKit pages take one flat list: a tool run is one row.
    func testFlatRowsPutOneChainInPlaceOfItsTools() {
        var first = item("t1", .tool(tool("web_search", .done)))
        first.time = Date(timeIntervalSince1970: 100)
        let items = [item("u", .message(.user, text: "play", state: .done)), first,
                     item("t2", .tool(tool("play_spotify", .running)))]
        let rows = ChatToolGrouping.rows(items, live: true)
        XCTAssertEqual(rows.map(\.id), ["u", "chain-t1"])
        guard case let .chain(_, tools, finished, time) = rows[1] else { return XCTFail() }
        XCTAssertEqual(tools.count, 2)
        XCTAssertFalse(finished)
        XCTAssertEqual(time, first.time, "Dated by its first call")
        XCTAssertTrue(ChatToolGrouping.endsWithRunningChain(rows), "The status line hides meanwhile")
        let saved = [first, item("t2", .tool(tool("play_spotify", .done)))]
        XCTAssertFalse(ChatToolGrouping.endsWithRunningChain(ChatToolGrouping.rows(saved, live: false)),
                       "A saved call's finished chain collapses")
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
                       "Playing Come Sail Away in Spotify")
        XCTAssertEqual(ChatToolSteps.label(tool("play_youtube", .failed, args: #"{"title":"Rick"}"#)), "Picked Rick (failed)")
    }

    func testSummaryNamesEachKindOnce() {
        let tools = [tool("web_search", .done), tool("play_spotify", .done), tool("open_in_spotify", .done)]
        XCTAssertEqual(ChatToolSteps.summary(tools), "Searched the web, opened Spotify")
        let many = tools + [tool("browser", .done), tool("open_map", .done)]
        XCTAssertEqual(ChatToolSteps.summary(many), "Searched the web, opened Spotify and 2 more")
    }

    /// The chain opens and closes inside `withAnimation`, so the rows after it and the
    /// transcript's scroll move with it. A scoped `.animation(_:value:)` animated only the
    /// chain: everything around it jumped to its final place in one frame (2026-11-26, 47 pt).
    func testChainHeightChangesAnimateTheWholeLayout() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ChatUI/ChatToolChain.swift"), encoding: .utf8)
        let chain = try XCTUnwrap(source.components(separatedBy: "private struct ChatToolStep").first)
        // A call, not the comments that name it (".animation(_:value:)").
        XCTAssertNil(chain.range(of: #"\.animation\((?!_:)"#, options: .regularExpression),
                     "Use animate { } (withAnimation), not .animation(_:value:)")
        XCTAssertTrue(chain.contains("withAnimation(Self.motion"))
        // Spacing that depends on open/closed belongs in the animated frame heights. Padding
        // inside a measured row is measured one update late, outside the animation: the rows
        // below jumped 6 pt in the first frame of every toggle (2026-11-27).
        XCTAssertNil(chain.range(of: #"\.padding\([^)]*\?"#, options: .regularExpression),
                     "No state-dependent padding in the chain: add it to the frame height")
    }
}
