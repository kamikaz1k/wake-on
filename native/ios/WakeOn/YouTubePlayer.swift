import UIKit
import UserNotifications

/// Pixie's "play something on YouTube" tool, the same way as `SpotifyPlayer`: the backend
/// model finds the youtube.com link with web search and calls `play_youtube`; the app ends the
/// call and opens it in the YouTube app (or Safari if the app isn't installed).
enum YouTubePlayer {
    static let toolName = "play_youtube"

    /// Function tool for Responses delegation (strict: every property required).
    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Open a video, short or playlist in the user's YouTube app. Call it when the user asks to watch something or to play something on YouTube.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "youtube_url": [
                    "type": "string",
                    "description": "The youtube.com or youtu.be link found with web search, for example https://www.youtube.com/watch?v=… Empty if none was found.",
                ],
                "query": [
                    "type": "string",
                    "description": "What to watch in plain words, such as \"Never Gonna Give You Up official video\". Used to search YouTube if there is no link.",
                ],
                "title": [
                    "type": "string",
                    "description": "Short name of what will play, such as \"Never Gonna Give You Up by Rick Astley\".",
                ],
            ],
            "required": ["youtube_url", "query", "title"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks to watch a video or to play something on YouTube, search the web for the \
    matching youtube.com link, then call play_youtube with it (empty youtube_url and a good \
    query if none turns up). Use play_youtube instead of play_spotify whenever the user says \
    YouTube or video; plain requests for music still go to play_spotify.
    """

    struct Request: Equatable {
        /// youtube.com link, opened as a universal link (the YouTube app, no prompt).
        var webURL: URL
        /// `youtube://` link, the fallback when the universal link doesn't open the app.
        var appURL: URL
        var title: String
    }

    /// Links for a tool call: the video, short or playlist from a YouTube link, else a search.
    static func request(youtubeURL: String, query: String, title: String) -> Request? {
        if let link = URL(string: youtubeURL.trimmingCharacters(in: .whitespaces)),
           let path = canonicalPath(link) {
            return Request(webURL: URL(string: "https://www.youtube.com\(path)")!,
                           appURL: URL(string: "youtube://www.youtube.com\(path)")!,
                           title: title.isEmpty ? query : title)
        }
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty,
              let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let path = "/results?search_query=\(encoded)"
        return Request(webURL: URL(string: "https://www.youtube.com\(path)")!,
                       appURL: URL(string: "youtube://www.youtube.com\(path)")!,
                       title: title.isEmpty ? words : title)
    }

    /// "/watch?v=<id>", "/shorts/<id>" or "/playlist?list=<id>" from any YouTube link form
    /// (youtube.com, m.youtube.com, music.youtube.com, youtu.be, /embed/, /live/).
    static func canonicalPath(_ link: URL) -> String? {
        guard let host = link.host?.lowercased() else { return nil }
        let isYouTube = host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
        guard isYouTube else { return nil }
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap(clean) }
        let parts = link.pathComponents.filter { $0 != "/" }
        if host == "youtu.be", let id = parts.first.flatMap(clean) { return "/watch?v=\(id)" }
        if let id = item("v") { return "/watch?v=\(id)" }
        if parts.count >= 2, parts[0] == "shorts", let id = clean(parts[1]) { return "/shorts/\(id)" }
        if parts.count >= 2, ["embed", "live", "v"].contains(parts[0]), let id = clean(parts[1]) { return "/watch?v=\(id)" }
        if let list = item("list") { return "/playlist?list=\(list)" }
        return nil
    }

    /// YouTube ids are letters, digits, "-" and "_"; anything else isn't one.
    private static func clean(_ id: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy(allowed.contains) ? id : nil
    }

    /// Opens it in YouTube. A background app can't open other apps, so then it posts a
    /// notification; tapping it opens the video (see `WakeController`).
    /// `done` gets "universal_link", "app_link", "safari", "notification" or "failed".
    @MainActor
    static func open(_ request: Request, done: (@MainActor (String) -> Void)? = nil) {
        guard UIApplication.shared.applicationState == .active else {
            let content = UNMutableNotificationContent()
            content.title = "Play on YouTube"
            content.body = "Tap to play \(request.title)."
            content.userInfo = ["youtubeWebURL": request.webURL.absoluteString,
                                "youtubeAppURL": request.appURL.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "youtube-play", content: content, trigger: nil))
            VoiceSessionController.appLog("youtube_notification \(request.webURL.absoluteString)")
            done?("notification")
            return
        }
        openNow(web: request.webURL, app: request.appURL, done: done)
    }

    /// The youtube.com link as a universal link first (the app, no prompt), then the
    /// `youtube://` link, then the page in Safari if the app isn't installed.
    @MainActor
    static func openNow(web: URL, app: URL, done: (@MainActor (String) -> Void)? = nil) {
        UIApplication.shared.open(web, options: [.universalLinksOnly: true]) { opened in
            VoiceSessionController.appLog("youtube_open universal \(web.absoluteString) opened=\(opened)")
            if opened { done?("universal_link"); return }
            UIApplication.shared.open(app) { opened in
                VoiceSessionController.appLog("youtube_open \(app.absoluteString) opened=\(opened)")
                if opened { done?("app_link"); return }
                UIApplication.shared.open(web) { opened in
                    VoiceSessionController.appLog("youtube_open safari opened=\(opened)")
                    done?(opened ? "safari" : "failed")
                }
            }
        }
    }
}
