import ActivityKit
import Foundation

/// The Live Activity shown while the "Hey Lobby" listener runs: the sky orb in the
/// Dynamic Island and on the Lock Screen. Shared by the app and the widget extension.
struct ListeningActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Mode: String, Codable, Hashable {
            /// Waiting for "Hey Lobby".
            case listening
            /// Just heard "Hey Lobby"; the conversation is connecting.
            case heard
            /// In a conversation with Lobby.
            case talking
            /// Another app has the microphone; listening comes back by itself.
            case paused
        }
        var mode: Mode
        /// When this mode began (call length while talking).
        var since: Date
    }
}
