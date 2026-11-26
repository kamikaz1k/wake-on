import Foundation

/// One row in a call transcript, independent of any chat library. Every renderer maps these
/// rows onto its own message type, so all libraries show the same replay.
struct ChatItem: Identifiable, Equatable {
    /// Raw values are the stored speaker ids (`Agent.speakerID` for the assistant), not display names.
    enum Speaker: String { case user = "You", lobby = "Lobby" }
    enum TextState: Equatable { case streaming, done, cutOff }
    enum ToolState: String, Equatable { case requested, running, done, failed }
    enum MarkerStyle: Equatable { case system, separator, error }

    struct Source: Equatable, Hashable { var title: String; var url: String }

    struct Tool: Equatable {
        var name: String
        var arguments: String
        var result: String?
        var state: ToolState
        var sources: [Source] = []
        /// A page from show_visual, shown in a web view.
        var visual: Visual?
        /// A place from open_map's show mode, shown as an embedded map.
        var place: Place?
    }

    struct Place: Equatable {
        var title: String
        var embedURL: String
        var webURL: String
    }

    struct Visual: Equatable {
        var title: String
        var html: String
        /// False while the model is still writing it.
        var complete: Bool
        /// An SF Symbol for it if it's saved as an app.
        var icon: String = ""
        /// The request that remakes it with fresh data; empty when it works on its own.
        var refresh: String = ""
    }

    struct RawEvent: Equatable {
        enum Direction: String { case sent = "↑ sent", received = "↓ received", app = "• app" }
        var direction: Direction
        var type: String
        var body: String
    }

    enum Card: Equatable {
        case chart(title: String, points: [Double])
        case image(systemName: String, caption: String)
        case buttons([String])
    }

    enum Kind: Equatable {
        case message(Speaker, text: String, state: TextState)
        case tool(Tool)
        case marker(String, MarkerStyle)
        case event(RawEvent)
        case card(Card)
    }

    let id: String
    var kind: Kind
    var time: Date = Date()
    /// Per-turn timing shown under a Pixie reply (E2), e.g. "Reply in 1.3 s".
    var timing: String?

    var speaker: Speaker? {
        if case let .message(speaker, _, _) = kind { return speaker }
        return nil
    }

    var text: String {
        switch kind {
        case let .message(_, text, _): text
        case let .tool(tool): tool.name
        case let .marker(text, _): text
        case let .event(event): "\(event.direction.rawValue) \(event.type)"
        case let .card(card):
            switch card {
            case let .chart(title, _): title
            case let .image(_, caption): caption
            case let .buttons(labels): labels.joined(separator: " · ")
            }
        }
    }

    var isUser: Bool { speaker == .user }
}

/// Call-level state a chat view may show around the transcript (B6, F4).
struct ChatCallState: Equatable {
    var status: String?       // live shimmer line, e.g. "Thinking…"
    var phase = "Live"        // Connecting, Live, Ended
    var muted = false
}
