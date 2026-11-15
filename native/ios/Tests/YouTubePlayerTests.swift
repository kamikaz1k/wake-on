import XCTest
@testable import WakeOn

final class YouTubePlayerTests: XCTestCase {
    private func web(_ link: String, query: String = "q") -> String? {
        YouTubePlayer.request(youtubeURL: link, query: query, title: "")?.webURL.absoluteString
    }

    func testVideoLinksInEveryForm() {
        let watch = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        XCTAssertEqual(web("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&si=abc"), watch)
        XCTAssertEqual(web("https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ"), watch)
        XCTAssertEqual(web("https://youtu.be/dQw4w9WgXcQ?si=xyz"), watch)
        XCTAssertEqual(web("https://www.youtube.com/embed/dQw4w9WgXcQ"), watch)
        XCTAssertEqual(web("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD1"), watch)
        XCTAssertEqual(web("https://www.youtube.com/shorts/abc_DEF-123"), "https://www.youtube.com/shorts/abc_DEF-123")
        XCTAssertEqual(web("https://www.youtube.com/playlist?list=PL1234_abc"), "https://www.youtube.com/playlist?list=PL1234_abc")
    }

    func testAppLinkAndTitle() {
        let request = YouTubePlayer.request(youtubeURL: "https://youtu.be/dQw4w9WgXcQ", query: "rick roll",
                                            title: "Never Gonna Give You Up")
        XCTAssertEqual(request?.appURL.absoluteString, "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(request?.title, "Never Gonna Give You Up")
    }

    func testNoLinkOrOtherSiteSearchesYouTube() {
        XCTAssertEqual(web("", query: "lo-fi beats"), "https://www.youtube.com/results?search_query=lo%2Dfi%20beats")
        XCTAssertEqual(web("https://open.spotify.com/track/x", query: "jazz"), "https://www.youtube.com/results?search_query=jazz")
        // Look-alike hosts and odd ids aren't trusted as links.
        XCTAssertEqual(web("https://notyoutube.com/watch?v=dQw4w9WgXcQ", query: "jazz"), "https://www.youtube.com/results?search_query=jazz")
        XCTAssertEqual(web("https://www.youtube.com/watch?v=bad%20id", query: "jazz"), "https://www.youtube.com/results?search_query=jazz")
        XCTAssertEqual(web("https://www.youtube.com/@channel", query: "jazz"), "https://www.youtube.com/results?search_query=jazz")
    }

    func testNothingToPlay() {
        XCTAssertNil(YouTubePlayer.request(youtubeURL: "", query: "  ", title: ""))
    }

    func testInstructionsSendVideosToYouTube() {
        let instructions = LiveVoiceConfig().backendInstructions()
        XCTAssertTrue(instructions.contains("play_youtube"))
        var config = LiveVoiceConfig()
        config.youtube = false
        XCTAssertFalse(config.backendInstructions().contains("play_youtube"))
    }
}
