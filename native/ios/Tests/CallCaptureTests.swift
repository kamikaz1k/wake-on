import XCTest
@testable import WakeOn

@MainActor
final class CallCaptureTests: XCTestCase {
    private var folder: URL!
    private var logsURL: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID())")
        folder = base.appendingPathComponent("call-captures")
        logsURL = base.appendingPathComponent("chat-logs.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

    private func log(_ capture: CallCapture) -> ChatLog {
        ChatLog(id: capture.id, started: Date(), ended: Date(), trigger: "wake_word",
                lines: [.init(speaker: "You", text: "Play something"), .init(speaker: "Lobby", text: "One moment")])
    }

    func testRecordsEverySourceInOrderWithTimes() {
        let origin: UInt64 = 1_000_000_000
        let capture = CallCapture(origin: origin)
        capture.app("call_started", ["trigger": "wake_word"], at: origin)
        capture.record(.server, ["type": "session.started"], at: origin + 250_000_000)
        capture.record(.client, ["type": "response.create", "delegation_id": NSNull()], at: origin + 1_500_000_000)
        let store = ChatLogStore(url: logsURL, capturesFolder: folder)
        XCTAssertTrue(store.add(log(capture), capture: capture))

        let lines = CallCapture.read(store.captureURL(for: capture.id)!)
        XCTAssertEqual(lines.map { $0["source"] as? String }, ["app", "server", "client"])
        XCTAssertEqual(lines.map { ($0["event"] as? [String: Any])?["type"] as? String },
                       ["app.call_started", "session.started", "response.create"])
        XCTAssertEqual(lines.map { $0["t_ms"] as? Double }, [0, 250, 1500])
    }

    /// Spotify opens after the call has ended and been saved: those events still land in the file.
    func testEventsAfterSavingAreAppended() {
        let capture = CallCapture(origin: DispatchTime.now().uptimeNanoseconds)
        capture.app("call_ended", ["reason": "spotify"])
        let store = ChatLogStore(url: logsURL, capturesFolder: folder)
        store.add(log(capture), capture: capture)
        capture.app("spotify_open", ["app_url": "spotify:track:abc"])
        capture.app("spotify_opened", ["outcome": "universal_link"])
        let types = CallCapture.read(store.captureURL(for: capture.id)!).map { ($0["event"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types, ["app.call_ended", "app.spotify_open", "app.spotify_opened"])
    }

    func testDeletingTheLogDeletesItsCapture() {
        let capture = CallCapture(origin: 0)
        capture.app("call_started")
        let store = ChatLogStore(url: logsURL, capturesFolder: folder)
        store.add(log(capture), capture: capture)
        XCTAssertNotNil(store.captureURL(for: capture.id))
        store.delete(ids: [capture.id])
        XCTAssertNil(store.captureURL(for: capture.id))
    }

    func testCallWithNothingSaidKeepsNoCapture() {
        let capture = CallCapture(origin: 0)
        capture.app("call_started")
        let store = ChatLogStore(url: logsURL, capturesFolder: folder)
        XCTAssertFalse(store.add(ChatLog(id: capture.id, started: Date(), ended: Date(), trigger: "in_app", lines: []), capture: capture))
        XCTAssertNil(store.captureURL(for: capture.id))
    }

    /// Milestone fields may hold values JSON can't encode; they're kept as text, not dropped.
    func testNonJSONValuesBecomeText() {
        let capture = CallCapture(origin: 0)
        capture.app("milestone", ["name": "ice_gathering_done", "fields": ["timeout": Duration.seconds(3), "candidates": 2]])
        let store = ChatLogStore(url: logsURL, capturesFolder: folder)
        store.add(log(capture), capture: capture)
        let event = CallCapture.read(store.captureURL(for: capture.id)!).first?["event"] as? [String: Any]
        let fields = event?["fields"] as? [String: Any]
        XCTAssertEqual(fields?["candidates"] as? Int, 2)
        XCTAssertNotNil(fields?["timeout"] as? String)
    }
}
