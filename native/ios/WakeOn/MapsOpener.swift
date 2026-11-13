import UIKit
import UserNotifications

/// Lobby's Google Maps tool. The backend model finds the place's address (web search if
/// needed) and calls `open_map`. Mode show puts an embedded Google Map in the chat with a link
/// out, and the call goes on. Directions and search work like play_spotify: the app ends the
/// call and opens Google Maps. No Google account or API key is involved.
enum MapsOpener {
    static let toolName = "open_map"

    enum Mode: String, CaseIterable { case show, directions, search }
    enum Travel: String, CaseIterable { case driving, walking, transit, bicycling }

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Show a place on a map in the chat, or open it in the user's Google Maps app with directions or a search. Call it when the user asks where a place is, for a map, for directions, or to open a place in Maps.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "place": ["type": "string", "description": "The place's name, such as \"Demetres\". Empty for a plain address."],
                "address": ["type": "string", "description": "Full street address with city, such as \"9174 Yonge St, Richmond Hill, ON\". Empty if unknown."],
                "mode": ["type": "string", "enum": Mode.allCases.map(\.rawValue),
                         "description": "show to put a map on their screen while the call goes on; directions to open Google Maps with directions; search to open the place in Google Maps."],
                "travel": ["type": "string", "enum": Travel.allCases.map(\.rawValue),
                           "description": "How they are getting there; driving unless they said otherwise."],
            ],
            "required": ["place", "address", "mode", "travel"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks where a place is, about a location you are recommending, for a map, \
    for directions, or to open a place in Maps or Google Maps, call open_map with the place's \
    name and full street address; search the web for the address first if you don't know it. \
    Use mode show by default: a map with a link to Google Maps appears on their screen and the \
    call goes on, so say it is on their screen. Use directions when they want to go there or ask \
    for directions, and search when they ask to open it in Maps: those open Google Maps and end \
    the call, so reply with only a short sentence such as "Opening directions to Demetres."
    """

    struct Request: Equatable {
        var title: String
        /// google.com/maps link: opens the Google Maps app when it's installed, else the web.
        var webURL: URL
        /// comgooglemaps: link, used if the web link doesn't open the app.
        var appURL: URL
        var mode: Mode
        /// Embeddable Google Map of the place, for mode show.
        var embedURL: URL
    }

    /// Google Maps links for a tool call (Maps URLs, developers.google.com/maps/documentation/urls).
    static func request(place: String, address: String, mode: String, travel: String) -> Request? {
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = [place, address].filter { !$0.isEmpty }.joined(separator: ", ")
        guard !query.isEmpty else { return nil }
        let mode = Mode(rawValue: mode) ?? .directions
        let travel = Travel(rawValue: travel) ?? .driving
        let q = encode(query)
        let web: String, app: String
        switch mode {
        case .directions:
            web = "https://www.google.com/maps/dir/?api=1&destination=\(q)&travelmode=\(travel.rawValue)"
            app = "comgooglemaps://?daddr=\(q)&directionsmode=\(travel.rawValue)"
        case .search, .show:
            web = "https://www.google.com/maps/search/?api=1&query=\(q)"
            app = "comgooglemaps://?q=\(q)"
        }
        // The keyless embed (output=embed) that Google's own "Embed a map" share uses.
        guard let webURL = URL(string: web), let appURL = URL(string: app),
              let embedURL = URL(string: "https://maps.google.com/maps?q=\(q)&z=15&output=embed") else { return nil }
        return Request(title: place.isEmpty ? address : place, webURL: webURL, appURL: appURL, mode: mode, embedURL: embedURL)
    }

    /// Percent-encodes everything but unreserved characters, so "&", "+" and "#" in a name
    /// can't break the link.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    /// Opens Google Maps. A background app can't open other apps, so then it posts a
    /// notification; tapping it opens the place (see `WakeController`).
    /// `done` gets how it went: "universal_link", "app_link", "web", "notification" or "failed".
    @MainActor
    static func open(_ request: Request, done: (@MainActor (String) -> Void)? = nil) {
        guard UIApplication.shared.applicationState == .active else {
            let content = UNMutableNotificationContent()
            content.title = request.mode == .directions ? "Directions in Google Maps" : "Open in Google Maps"
            content.body = "Tap to open \(request.title)."
            content.userInfo = ["mapsWebURL": request.webURL.absoluteString, "mapsAppURL": request.appURL.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "maps-open", content: content, trigger: nil))
            VoiceSessionController.appLog("maps_notification \(request.webURL.absoluteString)")
            done?("notification")
            return
        }
        openNow(web: request.webURL, app: request.appURL, done: done)
    }

    /// The google.com/maps link as a universal link first (no "Open in…?" prompt), then the
    /// comgooglemaps: link, then the web link in Safari when Google Maps isn't installed.
    @MainActor
    static func openNow(web: URL, app: URL, done: (@MainActor (String) -> Void)? = nil) {
        UIApplication.shared.open(web, options: [.universalLinksOnly: true]) { opened in
            VoiceSessionController.appLog("maps_open universal \(web.absoluteString) opened=\(opened)")
            if opened { done?("universal_link"); return }
            UIApplication.shared.open(app) { opened in
                VoiceSessionController.appLog("maps_open \(app.absoluteString) opened=\(opened)")
                if opened { done?("app_link"); return }
                UIApplication.shared.open(web) { opened in
                    VoiceSessionController.appLog("maps_open web opened=\(opened)")
                    done?(opened ? "web" : "failed")
                }
            }
        }
    }
}
