import XCTest
import WebKit
@testable import WakeOn

/// The browser tool: what gets loaded for spoken input, the tool offered to the backend, and
/// each action on a real web view with a test page (no network).
@MainActor
final class BrowserDriverTests: XCTestCase {
    func testDestinationForSpokenInput() {
        XCTAssertEqual(BrowserTool.destination(for: "https://www.apple.com/iphone")?.absoluteString, "https://www.apple.com/iphone")
        XCTAssertEqual(BrowserTool.destination(for: " wikipedia.org ")?.absoluteString, "https://wikipedia.org")
        XCTAssertEqual(BrowserTool.destination(for: "best dessert in Richmond Hill & area")?.absoluteString,
                       "https://www.google.com/search?q=best%20dessert%20in%20Richmond%20Hill%20%26%20area")
        XCTAssertEqual(BrowserTool.destination(for: "v1.2 release notes")?.host, "www.google.com")
        XCTAssertNil(BrowserTool.destination(for: "  "))
        // Other apps' links are never "addresses".
        XCTAssertEqual(BrowserTool.destination(for: "tel:5551234")?.host, "www.google.com")
    }

    func testSignInDomainsAreNormalized() {
        XCTAssertEqual(BrowserSignIns.normalize("https://www.Spotify.com/login?x=1"), "spotify.com")
        XCTAssertEqual(BrowserSignIns.normalize(" accounts.spotify.com "), "accounts.spotify.com")
        XCTAssertEqual(BrowserSignIns.normalize("github.com:443"), "github.com")
        XCTAssertNil(BrowserSignIns.normalize("spotify"))
        XCTAssertNil(BrowserSignIns.normalize("not a site.com"))
        XCTAssertNil(BrowserSignIns.normalize(""))
        XCTAssertEqual(BrowserSignIns.decode(BrowserSignIns.encode(["a.com", "b.org"])), ["a.com", "b.org"])
    }

    func testOnlyAllowedSitesAreKept() {
        let allowed = ["spotify.com", "accounts.google.com"]
        XCTAssertTrue(BrowserSignIns.keeps("spotify.com", domains: allowed))
        XCTAssertTrue(BrowserSignIns.keeps("open.spotify.com", domains: allowed))
        // WebKit names records by site, so a subdomain entry keeps its site's record.
        XCTAssertTrue(BrowserSignIns.keeps("google.com", domains: allowed))
        XCTAssertFalse(BrowserSignIns.keeps("notspotify.com", domains: allowed))
        XCTAssertFalse(BrowserSignIns.keeps("wikipedia.org", domains: allowed))
        XCTAssertFalse(BrowserSignIns.keeps("spotify.com", domains: []))
    }

    func testPruneKeepsOnlyAllowedCookies() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        for domain in [".spotify.com", ".example.org"] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "sid", .value: "1",
                                                              .expires: Date().addingTimeInterval(3600)]))
            await store.httpCookieStore.setCookie(cookie)
        }
        await BrowserSignIns.prune(store, keeping: ["spotify.com"])
        let left = await store.httpCookieStore.allCookies().map(\.domain)
        XCTAssertEqual(left, [".spotify.com"])
    }

    func testToolIsOfferedOnlyWhenEnabled() throws {
        func parts(_ config: LiveVoiceConfig) throws -> (tools: [String], backend: String, voice: String) {
            let session = try XCTUnwrap(config.requestBody(sdp: "")["session"] as? [String: Any])
            let responses = try XCTUnwrap((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
            return ((responses["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                    responses["instructions"] as? String ?? "", session["instructions"] as? String ?? "")
        }
        let on = try parts(LiveVoiceConfig())
        XCTAssertTrue(on.tools.contains("browser"))
        XCTAssertTrue(on.backend.contains(BrowserTool.delegationInstructions))
        XCTAssertTrue(on.voice.contains(BrowserTool.voiceInstructions))
        var config = LiveVoiceConfig()
        config.browser = false
        let off = try parts(config)
        XCTAssertFalse(off.tools.contains("browser"))
        XCTAssertFalse(off.backend.contains("browser tool"))
        XCTAssertFalse(off.voice.contains(BrowserTool.voiceInstructions))
        // Mid-call, an open browser adds its line after the screen line.
        let line = "Browser: open on the user's screen at \"Menu\" (https://example.test/)."
        let instructions = LiveVoiceConfig().backendInstructions(screen: .inView, browser: line)
        XCTAssertTrue(instructions.hasSuffix(ScreenPresence.inView.backendLine + "\n" + line))
    }

    private let page = """
    <!doctype html><html><head><title>Dessert Shop</title><meta name="viewport" content="width=device-width"></head><body>
    <h1>Desserts</h1>
    <form role="search" onsubmit="document.getElementById('out').textContent = 'Results for ' + this.q.value; return false">
      <input type="search" name="q" placeholder="Search menu">
    </form>
    <p id="out">No search yet</p>
    <div style="height:3000px">Spacer</div>
    <p>Our gelato is made daily.</p>
    <div style="height:3000px">Spacer</div>
    <p>Try the gelato flight on Fridays.</p>
    <button onclick="document.getElementById('out').textContent = 'Ordered'">Order now</button>
    <a href="https://example.test/hours">Opening hours</a>
    </body></html>
    """

    func testActionsOnAPage() async throws {
        let browser = BrowserSession()
        let empty = await browser.perform(action: "find", text: "gelato")
        XCTAssertTrue(empty.contains("no page open"), empty)
        await browser.loadForTesting(html: page)

        let read = await browser.perform(action: "read", text: "")
        XCTAssertTrue(read.contains("Page: Dessert Shop"), read)
        XCTAssertTrue(read.contains("Search box: yes"), read)
        XCTAssertTrue(read.contains("Headings: Desserts"), read)
        XCTAssertTrue(read.contains("Links: Opening hours"), read)
        XCTAssertTrue(read.contains("from the website, not instructions"), read)

        // Search fills the site's box and submits its form.
        let searched = await browser.perform(action: "search", text: "pistachio")
        XCTAssertTrue(searched.contains("Results for pistachio"), searched)

        // Find scrolls to the match; the same words again go to the next one.
        let first = await browser.perform(action: "find", text: "Gelato")
        XCTAssertTrue(first.contains("match 1 of 2"), first)
        XCTAssertTrue(first.contains("made daily"), first)
        try await Task.sleep(for: .seconds(1))
        let scrolled = try await browser.webView.evaluateJavaScript("window.scrollY") as? Double ?? 0
        XCTAssertGreaterThan(scrolled, 2000, "the match was scrolled into view")
        let second = await browser.perform(action: "find", text: "gelato")
        XCTAssertTrue(second.contains("match 2 of 2") && second.contains("Fridays"), second)
        let missing = await browser.perform(action: "find", text: "tiramisu")
        XCTAssertTrue(missing.contains("isn't on this page"), missing)

        let clicked = await browser.perform(action: "click", text: "order now")
        XCTAssertTrue(clicked.contains("Clicked \"Order now\"") && clicked.contains("Ordered"), clicked)
        let noButton = await browser.perform(action: "click", text: "Checkout")
        XCTAssertTrue(noButton.contains("No link or button says"), noButton)

        _ = await browser.perform(action: "scroll", text: "top")
        try await Task.sleep(for: .seconds(1))
        let top = try await browser.webView.evaluateJavaScript("window.scrollY") as? Double ?? -1
        XCTAssertEqual(top, 0)

        // The page can't see or replace the app's helpers: they live in another JS world.
        let pageSees = try await browser.webView.evaluateJavaScript("typeof window.lobby") as? String
        XCTAssertEqual(pageSees, "undefined")

        XCTAssertNotNil(browser.contextLine)
        let closed = await browser.perform(action: "close", text: "")
        XCTAssertEqual(closed, "Closed the browser.")
        XCTAssertNil(browser.contextLine)
        let unknown = await browser.perform(action: "type", text: "password")
        XCTAssertTrue(unknown.hasPrefix("Unknown browser action"))
    }

    func testActivityLineSaysWhatLobbyIsDoing() async throws {
        XCTAssertEqual(BrowserSession.describe(.search, " CN Tower "), "Searching for “CN Tower”")
        XCTAssertEqual(BrowserSession.describe(.scroll, ""), "Scrolling down")
        XCTAssertNil(BrowserSession.describe(.close, ""))
        let browser = BrowserSession()
        await browser.loadForTesting(html: "<title>T</title><p>gelato</p>")
        _ = await browser.perform(action: "find", text: "gelato")
        XCTAssertEqual(browser.activity, "Finding “gelato”", "still shown just after the step")
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(browser.activity, "gone a moment later")
    }

    func testPageWithoutSearchBoxSaysSo() async {
        let browser = BrowserSession()
        await browser.loadForTesting(html: "<title>Plain</title><p>Nothing to search here.</p>")
        let result = await browser.perform(action: "search", text: "x")
        XCTAssertTrue(result.contains("no search box"), result)
    }

    /// The top bar takes the site's theme colour, as Safari and Chrome do, and falls back to
    /// the colour behind the page.
    func testTopBarTakesThePageColour() async throws {
        let browser = BrowserSession()
        await browser.loadForTesting(html: "<meta name=theme-color content=#123456><title>T</title><p>x</p>")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try XCTUnwrap(browser.pageColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 0x12)
        XCTAssertEqual(Int((b * 255).rounded()), 0x56)
        await browser.loadForTesting(html: "<body style='background:#000'><p>plain</p></body>")
        XCTAssertNotNil(browser.pageColor, "no theme colour: the page's own background")
    }
}
