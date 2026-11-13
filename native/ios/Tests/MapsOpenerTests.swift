import XCTest
@testable import WakeOn

/// open_map: Google Maps links from the tool's arguments, the tool offered to the backend, and
/// the chat rows for opening Maps after the call.
@MainActor
final class MapsOpenerTests: XCTestCase {
    func testDirectionsLinks() throws {
        let request = try XCTUnwrap(MapsOpener.request(place: "Demetres", address: "9174 Yonge St, Richmond Hill, ON",
                                                       mode: "directions", travel: "driving"))
        XCTAssertEqual(request.title, "Demetres")
        XCTAssertEqual(request.webURL.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=Demetres%2C%209174%20Yonge%20St%2C%20Richmond%20Hill%2C%20ON&travelmode=driving")
        XCTAssertEqual(request.appURL.absoluteString,
                       "comgooglemaps://?daddr=Demetres%2C%209174%20Yonge%20St%2C%20Richmond%20Hill%2C%20ON&directionsmode=driving")
    }

    func testSearchLinksAndAwkwardNames() throws {
        let request = try XCTUnwrap(MapsOpener.request(place: "Tim Hortons & Co. #4+", address: "", mode: "search", travel: "walking"))
        XCTAssertEqual(request.webURL.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=Tim%20Hortons%20%26%20Co.%20%234%2B")
        XCTAssertEqual(request.appURL.absoluteString, "comgooglemaps://?q=Tim%20Hortons%20%26%20Co.%20%234%2B")
        let query = URLComponents(url: request.webURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }
        XCTAssertEqual(query?.value, "Tim Hortons & Co. #4+")
        // Unknown values fall back to driving directions; nothing to open gives no request.
        let fallback = try XCTUnwrap(MapsOpener.request(place: "", address: "1 Yonge St", mode: "fly", travel: "jetpack"))
        XCTAssertEqual(fallback.title, "1 Yonge St")
        XCTAssertTrue(fallback.webURL.absoluteString.contains("/dir/") && fallback.webURL.absoluteString.hasSuffix("travelmode=driving"))
        XCTAssertNil(MapsOpener.request(place: " ", address: "", mode: "search", travel: "driving"))
    }

    func testSessionOffersOpenMapToTheBackend() throws {
        let session = try XCTUnwrap(LiveVoiceConfig().requestBody(sdp: "")["session"] as? [String: Any])
        let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let names = (responses["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("open_map"))
        XCTAssertTrue((responses["instructions"] as? String ?? "").contains("open_map"))
        XCTAssertTrue((session["instructions"] as? String ?? "").contains("Google Maps"))
    }

    func testChatShowsMapsOpeningAndWhyTheCallEnded() throws {
        func line(_ t: Double, _ source: String, _ event: [String: Any]) -> CapturedCall.Line {
            CapturedCall.Line(t: t, source: source, event: event)
        }
        let web = "https://www.google.com/maps/dir/?api=1&destination=Demetres&travelmode=driving"
        let lines = [
            line(0, "app", ["type": "app.call_started", "trigger": "in_app"]),
            line(1, "server", ["type": "session.input_transcript.delta", "delta": " Directions to Demetres."]),
            line(2, "server", ["type": "session.delegation.created"]),
            line(3, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.added", "item": ["type": "function_call", "id": "fc", "call_id": "c", "name": "open_map"]]]),
            line(3.2, "server", ["type": "response.event", "delegation_id": "d", "event": ["type": "response.output_item.done", "item": ["type": "function_call", "id": "fc", "call_id": "c", "name": "open_map", "arguments": #"{"place":"Demetres","address":"","mode":"directions","travel":"driving"}"#]]]),
            line(3.3, "app", ["type": "app.tool_call", "name": "open_map", "call_id": "c", "output": "Opening Demetres in Google Maps; the call is ending."]),
            line(4, "app", ["type": "app.call_ended", "reason": "maps", "map_pending": true, "spotify_pending": false]),
            line(4.2, "app", ["type": "app.map_open", "title": "Demetres", "mode": "directions", "web_url": web, "app_url": "comgooglemaps://?daddr=Demetres"]),
            line(4.3, "app", ["type": "app.map_opened", "outcome": "universal_link"]),
        ]
        let items = ChatTranscript(steps: CaptureReplay(lines: lines, rawEvents: false).steps, startedAt: Date()).items
        let tools = items.compactMap { item -> ChatItem.Tool? in if case let .tool(tool) = item.kind { tool } else { nil } }
        XCTAssertEqual(tools.map(\.name), ["open_map", "open_in_google_maps"])
        XCTAssertEqual(tools.map(\.state), [.done, .done])
        XCTAssertEqual(tools[1].result, "Opened in Google Maps (google.com/maps link)")
        XCTAssertEqual(tools[1].sources, [.init(title: "Demetres", url: web)])
        XCTAssertTrue(items.contains { $0.kind == .marker("Call ended · 0:04 · ended to open Google Maps", .system) })
    }

    func testShowModeEmbedsAMapAndTheCallGoesOn() throws {
        let request = try XCTUnwrap(MapsOpener.request(place: "Demetres", address: "9174 Yonge St, Richmond Hill, ON",
                                                       mode: "show", travel: "driving"))
        XCTAssertEqual(request.mode, .show)
        XCTAssertEqual(request.embedURL.absoluteString,
                       "https://maps.google.com/maps?q=Demetres%2C%209174%20Yonge%20St%2C%20Richmond%20Hill%2C%20ON&z=15&output=embed")
        XCTAssertTrue(request.webURL.absoluteString.hasPrefix("https://www.google.com/maps/search/?api=1&query=Demetres"))
        // The made-up sample: the tool row becomes a map with a link out, and Lobby keeps talking.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../ChatLab/Captures/sample-place.jsonl")
        let call = try XCTUnwrap(CapturedCall.load(url))
        let items = ChatTranscript(steps: CaptureReplay(lines: call.lines, rawEvents: false).steps, startedAt: Date()).items
        let place = try XCTUnwrap(items.compactMap { item -> ChatItem.Place? in
            if case let .tool(tool) = item.kind { tool.place } else { nil }
        }.first)
        XCTAssertEqual(place, ChatItem.Place(title: "Demetres", embedURL: request.embedURL.absoluteString,
                                             webURL: request.webURL.absoluteString))
        XCTAssertTrue(items.contains { $0.kind == .message(.lobby, text: "It's at 9174 Yonge, just south of Highway 7. The map's on your screen.", state: .done) })
        XCTAssertTrue(items.contains { $0.kind == .marker("Call ended · 0:12 · ended after goodbye", .system) } ||
                      items.contains { if case let .marker(text, _) = $0.kind { text.hasSuffix("ended after goodbye") } else { false } })
    }
}
