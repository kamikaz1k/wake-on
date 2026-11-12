import UIKit
import UserNotifications

/// Lobby's "play something on Spotify" tool. The backend model finds the item's
/// open.spotify.com link with web search and calls `play_spotify`; the app ends the call and
/// opens the item in the Spotify app. No Spotify account or API key is involved.
enum SpotifyPlayer {
    static let toolName = "play_spotify"

    /// Function tool for Responses delegation (strict: every property required).
    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Open a song, album, playlist or artist in the user's Spotify app. Call it when the user asks to play music.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "spotify_url": [
                    "type": "string",
                    "description": "The open.spotify.com link found with web search, for example https://open.spotify.com/track/… Empty if none was found.",
                ],
                "query": [
                    "type": "string",
                    "description": "What to play in plain words, such as \"Blinding Lights The Weeknd\". Used to search in Spotify if there is no link.",
                ],
                "title": [
                    "type": "string",
                    "description": "Short name of what will play, such as \"Blinding Lights by The Weeknd\".",
                ],
            ],
            "required": ["spotify_url", "query", "title"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks to play music, search the web for the matching open.spotify.com link (a \
    track unless they ask for an album, playlist or artist), then call play_spotify with it. If \
    no link turns up, call it with an empty spotify_url and a good query.
    """

    struct Request: Equatable {
        var appURL: URL
        var webURL: URL?
        var title: String
    }

    /// The Spotify app link for a tool call: `spotify:track:<id>` from an open.spotify.com link,
    /// else a Spotify search for the query.
    static func request(spotifyURL: String, query: String, title: String) -> Request? {
        if let web = URL(string: spotifyURL.trimmingCharacters(in: .whitespaces)),
           web.host?.hasSuffix("spotify.com") == true {
            // Paths look like /track/<id> or /intl-fr/track/<id>.
            let parts = web.pathComponents.filter { $0 != "/" }
            let kinds = ["track", "album", "playlist", "artist", "episode", "show"]
            if let index = parts.firstIndex(where: kinds.contains), index + 1 < parts.count,
               let app = URL(string: "spotify:\(parts[index]):\(parts[index + 1])") {
                return Request(appURL: app, webURL: web, title: title.isEmpty ? query : title)
            }
        }
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty,
              let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let app = URL(string: "spotify:search:\(encoded)") else { return nil }
        return Request(appURL: app, webURL: URL(string: "https://open.spotify.com/search/\(encoded)"),
                       title: title.isEmpty ? words : title)
    }

    /// Opens the item in Spotify. A background app can't open other apps, so then it posts a
    /// notification; tapping it opens the item (see `WakeController`).
    /// `done` gets how it went: "universal_link", "app_link", "notification" or "failed".
    @MainActor
    static func open(_ request: Request, done: (@MainActor (String) -> Void)? = nil) {
        guard UIApplication.shared.applicationState == .active else {
            let content = UNMutableNotificationContent()
            content.title = "Play on Spotify"
            content.body = "Tap to play \(request.title)."
            content.userInfo = ["spotifyURL": request.appURL.absoluteString,
                                "spotifyWebURL": request.webURL?.absoluteString ?? ""]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "spotify-play", content: content, trigger: nil))
            VoiceSessionController.appLog("spotify_notification \(request.appURL.absoluteString)")
            done?("notification")
            return
        }
        openNow(app: request.appURL, web: request.webURL, done: done)
    }

    /// The open.spotify.com link first, as a universal link: Spotify opens it directly, while a
    /// `spotify:` link makes iOS ask "Open in Spotify?". The `spotify:` link is the fallback.

    @MainActor
    static func openNow(app: URL, web: URL?, done: (@MainActor (String) -> Void)? = nil) {
        guard let web else { return openScheme(app, done: done) }
        UIApplication.shared.open(web, options: [.universalLinksOnly: true]) { opened in
            VoiceSessionController.appLog("spotify_open universal \(web.absoluteString) opened=\(opened)")
            if opened { done?("universal_link") } else { openScheme(app, done: done) }
        }
    }

    @MainActor
    private static func openScheme(_ app: URL, done: (@MainActor (String) -> Void)?) {
        UIApplication.shared.open(app) { opened in
            VoiceSessionController.appLog("spotify_open \(app.absoluteString) opened=\(opened)")
            done?(opened ? "app_link" : "failed")
        }
    }
}
