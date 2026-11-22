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

    /// Regression (Nov 2026): launched while the phone was locked, the store couldn't read the
    /// file, started empty, and the next call saved over every older log.
    func testUnreadableFileIsNeverSavedOver() throws {
        let now = Date()
        let first = ChatLogStore(url: url)
        first.add(log(daysAgo: 3, "older one", now: now))
        first.add(log(daysAgo: 2, "older two", now: now))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let locked = ChatLogStore(url: url)
        locked.add(log(daysAgo: 0, "new while locked", now: now))
        XCTAssertEqual(locked.logs.map(\.title), ["new while locked"])

        // Unlocked: the old logs come back, merged with the new one, and all are saved.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(ChatLogStore(url: url).logs.map(\.title), ["older two", "older one"])
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertEqual(locked.logs.map(\.title), ["new while locked", "older two", "older one"])
        XCTAssertEqual(ChatLogStore(url: url).logs.map(\.title), ["new while locked", "older two", "older one"])
    }

    func testDamagedFileIsKeptAside() throws {
        try Data("not json".utf8).write(to: url)
        let store = ChatLogStore(url: url)
        store.add(log(daysAgo: 0, "fresh", now: Date()))
        XCTAssertEqual(ChatLogStore(url: url).logs.map(\.title), ["fresh"])
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(base + ".damaged-") }
        XCTAssertEqual(aside.count, 1)
        for name in aside { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}
