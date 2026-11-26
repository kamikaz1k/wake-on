import XCTest
@testable import WakeOn

/// Saved apps: pages from show_visual kept on the phone, opened, changed and refreshed.
@MainActor
final class MiniAppsTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private let page = "<!doctype html><html><body>Tip</body></html>"

    private func visual(_ title: String = "Tip Calculator", refresh: String = "", icon: String = "percent") -> ChatItem.Visual {
        ChatItem.Visual(title: title, html: page, complete: true, icon: icon, refresh: refresh)
    }

    func testSaveKeepsThePageAndSurvivesRelaunch() {
        let store = MiniAppStore(file: file)
        XCTAssertFalse(store.isSaved(visual()))
        XCTAssertTrue(store.save(visual()))
        XCTAssertTrue(store.save(visual()), "Saving again keeps one copy")
        XCTAssertEqual(store.apps.count, 1)
        XCTAssertTrue(store.isSaved(visual()))
        let again = MiniAppStore(file: file)
        XCTAssertEqual(again.apps.first?.name, "Tip Calculator")
        XCTAssertEqual(again.apps.first?.icon, "percent")
        XCTAssertFalse(again.apps.first?.isLive ?? true)
    }

    func testUnknownIconFallsBack() {
        XCTAssertEqual(MiniApps.icon("not.a.real.symbol"), "app")
        XCTAssertEqual(MiniApps.icon("cloud.sun"), "cloud.sun")
    }

    func testFindByIDOrName() {
        let store = MiniAppStore(file: file)
        let app = store.add(visual())
        XCTAssertEqual(store.find(app.shortID)?.id, app.id)
        XCTAssertEqual(store.find("tip calculator")?.id, app.id)
        XCTAssertEqual(store.find("my tip calculator app")?.id, app.id)
        XCTAssertNil(store.find("weather"))
        XCTAssertNil(store.find(""))
    }

    func testUpdateUndoRenameDelete() {
        let store = MiniAppStore(file: file)
        let app = store.add(visual())
        store.update(app.id, html: "<html>new</html>")
        XCTAssertEqual(store.app(app.id)?.html, "<html>new</html>")
        XCTAssertTrue(store.isSaved(visual()), "Still known by the page it started as")
        store.undo(app.id)
        XCTAssertEqual(store.app(app.id)?.html, page)
        XCTAssertNil(store.app(app.id)?.previousHTML)
        store.rename(app.id, to: "  Tips ")
        XCTAssertEqual(store.app(app.id)?.name, "Tips")
        store.open(store.app(app.id)!)
        store.delete(app.id)
        XCTAssertTrue(store.apps.isEmpty)
        XCTAssertNil(store.opened)
    }

    func testToolSavesTheLastPageAndOpensIt() {
        let store = MiniAppStore(file: file)
        XCTAssertTrue(MiniApps.perform(["action": "save"], lastVisual: nil, store: store).hasPrefix("Nothing to save"))
        let saved = MiniApps.perform(["action": "save", "name": "Tips"], lastVisual: visual(), store: store)
        XCTAssertTrue(saved.hasPrefix("Saved as \"Tips\""))
        XCTAssertTrue(MiniApps.perform(["action": "list"], lastVisual: nil, store: store).contains("Tips (works on its own)"))
        XCTAssertTrue(MiniApps.perform(["action": "open", "app": "tips"], lastVisual: nil, store: store).hasPrefix("Opened"))
        XCTAssertEqual(store.opened?.name, "Tips")
        XCTAssertEqual(MiniApps.perform(["action": "get", "app": "tips"], lastVisual: nil, store: store), page)
        XCTAssertTrue(MiniApps.perform(["action": "update", "app": "tips", "html": ""], lastVisual: nil, store: store).hasPrefix("Not updated"))
        _ = MiniApps.perform(["action": "update", "app": "tips", "html": "<html>rounded</html>"], lastVisual: nil, store: store)
        XCTAssertEqual(store.opened?.html, "<html>rounded</html>", "The open app shows the change")
        XCTAssertTrue(MiniApps.perform(["action": "open", "app": "news"], lastVisual: nil, store: store).hasPrefix("No saved app"))
    }

    func testShowVisualCarriesIconAndRefresh() {
        let json = #"{"title":"Weather","html":"<html></html>","icon":"cloud.sun","refresh":"This week's weather in Toronto"}"#
        let visual = ShowVisual.visual(fromArguments: json, complete: true)
        XCTAssertEqual(visual?.icon, "cloud.sun")
        XCTAssertEqual(visual?.refresh, "This week's weather in Toronto")
        let required = ((ShowVisual.tool["parameters"] as? [String: Any])?["required"] as? [String]) ?? []
        XCTAssertEqual(required, ["title", "html", "icon", "refresh"])
    }

    func testLiveAppRefreshesWhenStale() {
        var app = MiniApp(name: "Weather", icon: "cloud.sun", html: page, refresh: "This week's weather in Toronto", origin: "x")
        app.updated = Date().addingTimeInterval(-20 * 60)
        XCTAssertTrue(MiniAppRefresher.isStale(app))
        app.updated = Date().addingTimeInterval(-60)
        XCTAssertFalse(MiniAppRefresher.isStale(app))
        app.refresh = ""
        app.updated = .distantPast
        XCTAssertFalse(MiniAppRefresher.isStale(app), "A self-contained app never refreshes")
    }

    func testRefreshRequestAndReply() {
        let app = MiniApp(name: "Weather", icon: "cloud.sun", html: page, refresh: "This week's weather in Toronto", origin: "x")
        let request = MiniAppRefresher.request(app)
        XCTAssertEqual((request["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
        XCTAssertEqual(request["store"] as? Bool, false)
        let input = request["input"] as? String ?? ""
        XCTAssertTrue(input.hasPrefix("Now: "))
        XCTAssertTrue(input.contains("Request: This week's weather in Toronto"))
        XCTAssertTrue(input.contains(page))
        XCTAssertEqual(MiniAppRefresher.page(from: "Here it is:\n```html\n\(page)\n```"), page)
        XCTAssertNil(MiniAppRefresher.page(from: "Sorry, I couldn't find it."))
    }
}
