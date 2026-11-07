import XCTest
@testable import WakeOn

final class SpotifyPlayerTests: XCTestCase {
    func testTrackLinkBecomesAppLink() {
        let request = SpotifyPlayer.request(spotifyURL: "https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b?si=abc",
                                            query: "Blinding Lights", title: "Blinding Lights by The Weeknd")
        XCTAssertEqual(request?.appURL.absoluteString, "spotify:track:0VjIjW4GlUZAMYd2vXMi3b")
        XCTAssertEqual(request?.webURL?.host, "open.spotify.com")
        XCTAssertEqual(request?.title, "Blinding Lights by The Weeknd")
    }

    func testLocalizedPlaylistLink() {
        let request = SpotifyPlayer.request(spotifyURL: "https://open.spotify.com/intl-fr/playlist/37i9dQZF1DXcBWIGoYBM5M",
                                            query: "Today's Top Hits", title: "")
        XCTAssertEqual(request?.appURL.absoluteString, "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(request?.title, "Today's Top Hits")
    }

    func testNoLinkSearchesInSpotify() {
        let request = SpotifyPlayer.request(spotifyURL: "", query: "lo-fi beats", title: "")
        XCTAssertEqual(request?.appURL.absoluteString, "spotify:search:lo%2Dfi%20beats")
        XCTAssertNil(request?.webURL)
    }

    func testOtherSiteFallsBackToSearch() {
        let request = SpotifyPlayer.request(spotifyURL: "https://www.youtube.com/watch?v=x", query: "jazz", title: "")
        XCTAssertEqual(request?.appURL.absoluteString, "spotify:search:jazz")
    }

    func testNothingToPlay() {
        XCTAssertNil(SpotifyPlayer.request(spotifyURL: "", query: "  ", title: ""))
    }

    func testToolIsInTheSessionRequest() {
        let body = LiveVoiceConfig().requestBody(sdp: "v=0")
        let responses = ((body["session"] as? [String: Any])?["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        let names = (responses?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["play_spotify"])
        XCTAssertTrue((responses?["instructions"] as? String)?.contains("play_spotify") == true)
    }
}
