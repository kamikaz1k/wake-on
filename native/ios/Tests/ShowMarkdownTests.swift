import XCTest
@testable import WakeOn

/// Links and text on screen (show_markdown), and browser steps you can open again. From a call
/// where Pixie said "I can't send a link from here" (2026-11-27).
@MainActor
final class ShowMarkdownTests: XCTestCase {
    private func line(_ t: Double, _ source: String, _ event: [String: Any]) -> CapturedCall.Line {
        CapturedCall.Line(t: t, source: source, event: event)
    }

    private func tools(_ lines: [CapturedCall.Line]) -> [ChatItem.Tool] {
        ChatTranscript(steps: CaptureReplay(lines: lines, rawEvents: false).steps, startedAt: Date()).items
            .compactMap { item -> ChatItem.Tool? in if case let .tool(tool) = item.kind { tool } else { nil } }
    }

    func testToolIsOfferedAndThePixieIsToldItCanShowLinks() throws {
        let session = try XCTUnwrap(LiveVoiceConfig().requestBody(sdp: "v=0")["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let names = (responses["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains(ShowMarkdown.toolName))
        XCTAssertTrue((responses["instructions"] as? String)?.contains("call show_markdown") == true)
        let voice = session["instructions"] as? String ?? ""
        XCTAssertTrue(voice.contains("Never say you can't send a link"), "the voice model must know links can be shown")
    }

    func testMarkdownShowsAsItsOwnCardWithLinks() throws {
        let args = #"{"title":"Ken McElroy","markdown":"Read it: [FBI Closes Inquiry](https://www.washingtonpost.com/a)"}"#
        let shown = tools([
            line(1, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.added", "item": ["type": "function_call", "id": "fc", "call_id": "c", "name": "show_markdown"]]]),
            line(1.2, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.done", "item": ["type": "function_call", "id": "fc", "call_id": "c", "name": "show_markdown", "arguments": args]]]),
            line(1.3, "app", ["type": "app.tool_call", "name": "show_markdown", "call_id": "c", "output": "Shown."]),
        ])
        let markdown = try XCTUnwrap(shown.first?.markdown)
        XCTAssertEqual(markdown.title, "Ken McElroy")
        let link = ShowMarkdown.attributed(markdown.text).runs.compactMap(\.link).first
        XCTAssertEqual(link?.absoluteString, "https://www.washingtonpost.com/a")
        // A card of its own, not folded into a tool chain.
        XCTAssertNil(ChatToolGrouping.isChainable(ChatItem(id: "x", kind: .tool(shown[0]))))
    }

    func testBrowserStepsKeepThePageToOpenAgain() throws {
        func browser(_ t: Double, _ id: String, _ args: String, page: String, address: String) -> [CapturedCall.Line] {
            [line(t, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.added", "item": ["type": "function_call", "id": "fc\(id)", "call_id": "c\(id)", "name": "browser"]]]),
             line(t + 0.1, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.done", "item": ["type": "function_call", "id": "fc\(id)", "call_id": "c\(id)", "name": "browser", "arguments": args]]]),
             line(t + 0.2, "app", ["type": "app.tool_call", "name": "browser", "call_id": "c\(id)", "action": ["kind": "browser", "step": "open"],
                                   "output": "Opened the page.\nPage: \(page)\nAddress: \(address)\nSearch box: yes"])]
        }
        let steps = tools(browser(1, "1", #"{"action":"open","text":"McElroy Wikipedia"}"#, page: "McElroy Wikipedia - Google Search", address: "https://www.google.com/search?q=McElroy")
            + browser(2, "2", #"{"action":"click","text":"Ken McElroy"}"#, page: "Ken McElroy - Wikipedia", address: "https://en.wikipedia.org/wiki/Ken_McElroy"))
        XCTAssertEqual(steps.map { $0.page?.url }, ["https://www.google.com/search?q=McElroy", "https://en.wikipedia.org/wiki/Ken_McElroy"])
        XCTAssertEqual(ChatToolSteps.label(steps[0]), "Opened McElroy Wikipedia - Google Search")
        XCTAssertEqual(ChatToolSteps.summary(steps), "Opened Ken McElroy - Wikipedia")
        XCTAssertNil(BrowserPage.from(output: "Closed the browser."))
    }
}
