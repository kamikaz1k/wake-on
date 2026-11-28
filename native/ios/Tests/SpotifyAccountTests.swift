import XCTest
@testable import WakeOn

/// Spotify control through the user's own account (SpotifyAccount), so TestFlight builds can
/// pause, resume and skip Spotify without the private API (2026-11-28).
final class SpotifyAccountTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SpotifyAccount.connectedKey)
        super.tearDown()
    }

    func testEachCommandHitsItsPlayerEndpoint() {
        XCTAssertEqual(SpotifyAccount.endpoint(.pause).path, "/v1/me/player/pause")
        XCTAssertEqual(SpotifyAccount.endpoint(.pause).method, "PUT")
        XCTAssertEqual(SpotifyAccount.endpoint(.play).path, "/v1/me/player/play")
        XCTAssertEqual(SpotifyAccount.endpoint(.next).method, "POST")
        XCTAssertEqual(SpotifyAccount.endpoint(.previous).path, "/v1/me/player/previous")
    }

    func testSpotifyRepliesBecomeOutcomes() {
        func body(_ status: Int, _ message: String, _ reason: String? = nil) -> Data {
            var error: [String: Any] = ["status": status, "message": message]
            if let reason { error["reason"] = reason }
            return try! JSONSerialization.data(withJSONObject: ["error": error])
        }
        XCTAssertEqual(SpotifyAccount.outcome(status: 204, body: Data()), .done)
        XCTAssertEqual(SpotifyAccount.outcome(status: 404, body: body(404, "Player command failed: No active device found", "NO_ACTIVE_DEVICE")), .noActiveDevice)
        XCTAssertEqual(SpotifyAccount.outcome(status: 403, body: body(403, "Player command failed: Premium required", "PREMIUM_REQUIRED")), .premiumRequired)
        XCTAssertEqual(SpotifyAccount.outcome(status: 403, body: body(403, "User not registered in the Developer Dashboard")), .notAllowed)
        // Pausing something already paused: the user got what they asked for.
        XCTAssertEqual(SpotifyAccount.outcome(status: 403, body: body(403, "Player command failed: Restriction violated", "UNKNOWN")), .done)
        XCTAssertEqual(SpotifyAccount.outcome(status: 401, body: body(401, "The access token expired")), .signedOut)
        XCTAssertEqual(SpotifyAccount.outcome(status: 500, body: Data()), .failed("500"))
        XCTAssertNil(SpotifyAccount.Outcome.done.notice)
        XCTAssertNotNil(SpotifyAccount.Outcome.noActiveDevice.notice)
    }

    func testPKCEChallengeIsTheVerifiersSHA256() {
        // Worked out separately (Python hashlib + urlsafe base64, padding removed).
        XCTAssertEqual(SpotifyAccount.challenge(for: "dBjftJeZ4CVP-mJ92K9qOIp9-gDLzYz1lt9tCgZdfp4"),
                       "E34Vlca-PBt0G5gQJ2U-pJl2j_0vwBa6LSSaVlfihy0")
        let verifier = SpotifyAccount.randomVerifier()
        XCTAssertTrue((43...128).contains(verifier.count), "RFC 7636 length")
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    /// With Spotify connected, Release builds offer control_media too, limited to Spotify.
    func testConnectedSpotifyOffersTheToolForSpotifyOnly() throws {
        UserDefaults.standard.set(true, forKey: SpotifyAccount.connectedKey)
        XCTAssertTrue(MediaControl.offered)
        var config = LiveVoiceConfig()
        XCTAssertTrue(config.mediaControl)
        let session = try XCTUnwrap(config.requestBody(sdp: "v=0")["session"] as? [String: Any])
        let responses = ((session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        let names = (responses?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains(MediaControl.toolName))
        if !MediaControl.available {
            XCTAssertTrue((responses?["instructions"] as? String ?? "").contains(MediaControl.spotifyOnlyInstructions))
        }
        UserDefaults.standard.set(false, forKey: SpotifyAccount.connectedKey)
        config = LiveVoiceConfig()
        XCTAssertEqual(config.mediaControl, MediaControl.available)
    }
}

/// Playback steps in the chat read like what happened (2026-11-28: "Picked … by ABBA" for a
/// search, "Sent next" twice, "ended to next the music").
final class PlaybackStepsTests: XCTestCase {
    private func tool(_ name: String, _ arguments: String, _ result: String? = nil, _ state: ChatItem.ToolState = .done) -> ChatItem.Tool {
        ChatItem.Tool(name: name, arguments: arguments, result: result, state: state)
    }

    func testSpotifySearchIsNotCalledAPick() {
        let search = tool("play_spotify", #"{"title":"Holly Jolly Christmas by ABBA","spotify_url":"","query":"ABBA Holly Jolly Christmas"}"#)
        XCTAssertEqual(ChatToolSteps.label(search), "Searching Spotify for “ABBA Holly Jolly Christmas”")
        let found = tool("play_spotify", #"{"title":"Holly Jolly Christmas by Michael Bublé","spotify_url":"https://open.spotify.com/track/3eT","query":"x"}"#)
        XCTAssertEqual(ChatToolSteps.label(found), "Found Holly Jolly Christmas by Michael Bublé")
        XCTAssertEqual(ChatToolSteps.label(tool("open_in_spotify", "Holly Jolly Christmas by ABBA\nspotify:search:ABBA%20Holly%20Jolly%20Christmas")),
                       "Opened a Spotify search for “ABBA Holly Jolly Christmas”")
        XCTAssertEqual(ChatToolSteps.label(tool("open_in_spotify", "Holly Jolly Christmas by Michael Bublé\nspotify:track:3eT")),
                       "Playing Holly Jolly Christmas by Michael Bublé in Spotify")
    }

    func testSearchQueriesDropSiteFilters() {
        XCTAssertEqual(ChatToolSteps.label(tool("web_search", "site:open.spotify.com/track \"A Holly Jolly Christmas\" Burl Ives\nother")),
                       "Searched “A Holly Jolly Christmas Burl Ives”")
    }

    func testPlaybackCommandsInWords() {
        XCTAssertEqual(ChatToolSteps.label(tool("control_media", #"{"action":"next"}"#)), "Skipping to the next track")
        XCTAssertEqual(ChatToolSteps.label(tool("media_control", "next", "Spotify did it")), "Skipped to the next track in Spotify")
        XCTAssertEqual(ChatToolSteps.label(tool("media_control", "pause", "Sent to whatever is playing")), "Paused the music")
        XCTAssertEqual(ChatToolSteps.label(tool("media_control", "play", "Spotify had nothing playing on any device", .failed)),
                       "Resumed the music (failed)")
        XCTAssertEqual(ChatToolSteps.summary([tool("control_media", #"{"action":"next"}"#)]), "Skipping to the next track")
        XCTAssertEqual(ChatToolSteps.summary([tool("media_control", "next", "Spotify did it")]), "Skipped a track in Spotify")
        XCTAssertEqual(ChatToolSteps.summary([tool("web_search", "q"), tool("play_spotify", #"{"title":"t","spotify_url":"","query":"q"}"#)]),
                       "Searched the web, searched Spotify")
    }
}
