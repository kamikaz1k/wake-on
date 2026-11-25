import XCTest
@testable import WakeOn

/// show_visual: the page is read out of the tool's arguments as they stream, shown as a visual
/// row, and offered to the backend model in the session config.
@MainActor
final class ShowVisualTests: XCTestCase {
    func testReadsHTMLWhileArgumentsStream() {
        let full = #"{"title":"Paris \"week\"","html":"<p>a\nb é</p>"}"#
        XCTAssertEqual(ShowVisual.stringPrefix(of: "title", in: full), "Paris \"week\"")
        XCTAssertEqual(ShowVisual.stringPrefix(of: "html", in: full), "<p>a\nb é</p>")
        // Cut mid-string, mid-escape and mid-\u: everything read so far, nothing garbled.
        XCTAssertEqual(ShowVisual.stringPrefix(of: "html", in: #"{"title":"x","html":"<p>a"#), "<p>a")
        XCTAssertEqual(ShowVisual.stringPrefix(of: "html", in: #"{"title":"x","html":"<p>a\"#), "<p>a")
        XCTAssertEqual(ShowVisual.stringPrefix(of: "html", in: #"{"title":"x","html":"b \u00"#), "b ")
        XCTAssertNil(ShowVisual.stringPrefix(of: "html", in: #"{"title":"x","ht"#))
        XCTAssertNil(ShowVisual.visual(fromArguments: #"{"title":"x","html":""}"#, complete: true))
    }

    func testSampleCallShowsTheVisualFillingInThenComplete() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../ChatLab/Captures/sample-visual.jsonl")
        let call = try XCTUnwrap(CapturedCall.load(url))
        let live = LiveChat()
        var partial: ChatItem.Visual?
        for line in call.lines {
            live.add(line)
            for item in live.transcript.items {
                if case let .tool(tool) = item.kind, let visual = tool.visual, !visual.complete, partial == nil,
                   visual.html.count > 200 { partial = visual }
            }
        }
        let tools = live.transcript.items.compactMap { item -> ChatItem.Tool? in
            if case let .tool(tool) = item.kind { tool } else { nil }
        }
        let tool = try XCTUnwrap(tools.first { $0.name == ShowVisual.toolName })
        let visual = try XCTUnwrap(tool.visual)
        XCTAssertTrue(visual.complete)
        XCTAssertEqual(visual.title, "Paris this week")
        XCTAssertTrue(visual.html.hasPrefix("<!doctype html>") && visual.html.hasSuffix("</html>"))
        XCTAssertEqual(tool.state, .done)
        XCTAssertEqual(tool.arguments, "Paris this week")
        XCTAssertTrue(tool.result?.contains("Shown on the user's screen") == true)
        // Mid-stream, the row already had part of the page.
        let mid = try XCTUnwrap(partial)
        XCTAssertTrue(visual.html.hasPrefix(mid.html))
        // The call goes on: \(Agent.name) speaks after the visual, and the saved replay matches.
        let saved = ChatTranscript(steps: CaptureReplay(lines: call.lines, rawEvents: false).steps, startedAt: Date()).items
        XCTAssertEqual(live.transcript.items.map(\.kind), saved.map(\.kind))
        XCTAssertTrue(saved.contains { $0.kind == .message(.lobby, text: "It's on your screen: highs from 9 to 14 degrees.", state: .done) })
    }

    func testSessionOffersShowVisualToTheBackend() throws {
        let body = LiveVoiceConfig().requestBody(sdp: "")
        let session = try XCTUnwrap(body["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let names = (responses["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("show_visual"))
        XCTAssertTrue((responses["instructions"] as? String ?? "").contains("show_visual"))
        XCTAssertTrue((session["instructions"] as? String ?? "").contains("visualize"))
        var off = LiveVoiceConfig()
        off.visuals = false
        let offTools = ((off.requestBody(sdp: "")["session"] as? [String: Any])?["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        XCTAssertFalse((offTools?["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "show_visual" })
    }

    /// A bare brief got plain tables from real calls (Toronto's week as a text table, 2026-11-25).
    /// Rich data should get the widget treatment, short answers a plain card, and the size cap stays.
    func testBriefAsksForPolishOnRichDataAndStaysCompact() {
        let brief = ShowVisual.delegationInstructions
        XCTAssertTrue(brief.contains("Match the polish to the content"))
        XCTAssertTrue(brief.contains("low-to-high bar per day"))
        XCTAssertTrue(brief.contains("one clean card is enough"))
        XCTAssertTrue(brief.contains("about 5 KB at most"))
        XCTAssertTrue(brief.contains("prefers-color-scheme"))
    }
}
