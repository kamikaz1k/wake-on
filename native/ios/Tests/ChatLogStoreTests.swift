import XCTest
@testable import WakeOn

@MainActor
final class ChatLogStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-logs-\(UUID()).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func log(daysAgo: Double, _ said: String = "hi", now: Date) -> ChatLog {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return ChatLog(started: start, ended: start.addingTimeInterval(30), trigger: "wake_word",
                       lines: [.init(speaker: "You", text: said), .init(speaker: "Lobby", text: "Hello.")])
    }

    func testLogsPersistNewestFirst() {
        let now = Date()
        let store = ChatLogStore(url: url)
        store.add(log(daysAgo: 2, "older", now: now))
        store.add(log(daysAgo: 1, "newer", now: now))
        let reopened = ChatLogStore(url: url)
        XCTAssertEqual(reopened.logs.map(\.title), ["newer", "older"])
    }

    func testEmptyCallsAreNotSaved() {
        let store = ChatLogStore(url: url)
        store.add(ChatLog(started: Date(), ended: Date(), trigger: "in_app", lines: []))
        XCTAssertTrue(store.logs.isEmpty)
    }

    func testDeleteOne() {
        let now = Date()
        let store = ChatLogStore(url: url)
        store.add(log(daysAgo: 1, "keep", now: now))
        store.add(log(daysAgo: 0, "drop", now: now))
        store.delete(ids: [store.logs[0].id])
        XCTAssertEqual(ChatLogStore(url: url).logs.map(\.title), ["keep"])
    }

    func testDeleteOlderThanThirtyDays() {
        let now = Date()
        let store = ChatLogStore(url: url)
        store.add(log(daysAgo: 45, "old", now: now))
        store.add(log(daysAgo: 30.5, "just over", now: now))
        store.add(log(daysAgo: 29, "recent", now: now))
        XCTAssertEqual(Set(store.older(now: now).map(\.title)), ["old", "just over"])
        store.deleteOlder(now: now)
        XCTAssertEqual(ChatLogStore(url: url).logs.map(\.title), ["recent"])
    }

    func testTitleAndSource() {
        let lobbyOnly = ChatLog(started: Date(), ended: Date(), trigger: "app_intent_fast",
                                lines: [.init(speaker: "Lobby", text: "Anything else?")])
        XCTAssertEqual(lobbyOnly.title, "Lobby only")
        XCTAssertEqual(lobbyOnly.source, "Action Button")
    }
}
