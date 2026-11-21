import Foundation

/// Lobby's "pause / resume / skip what's playing" tool. Sends the same play/pause commands as
/// Control Center and AirPods, to whichever app is playing (Spotify, Podcasts, YouTube…),
/// through Apple's private MediaRemote framework. Works with the phone locked and Wake On in
/// the background (verified on iOS 26). Private API: fine for this sideloaded app, not for the
/// App Store. iOS hides the playback state from Wake On, so commands are sent blind.
enum MediaControl {
    static let toolName = "control_media"

    enum Command: String, CaseIterable {
        case pause, play, next, previous
        /// MRMediaRemoteCommand values.
        var code: UInt32 {
            switch self {
            case .play: 0
            case .pause: 1
            case .next: 4
            case .previous: 5
            }
        }
        /// Pause and play can be sent twice safely; skipping can't.
        var repeatable: Bool { self == .pause || self == .play }
    }

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Pause, resume, skip or go back in whatever music, podcast or video is playing on the user's phone, in any app.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": Command.allCases.map(\.rawValue),
                    "description": "pause (also for stop), play (resume), next (skip) or previous.",
                ],
            ],
            "required": ["action"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    /// For the voice model (added to its instructions when the tool is offered).
    static let voiceInstructions = """
    Also delegate requests to pause, stop, resume or skip whatever is playing; the call ends \
    after that too.
    """

    static let delegationInstructions = """
    To pause or stop, resume, skip or go back in whatever is already playing, call control_media \
    instead of play_spotify.
    """

    /// Only in Debug builds (sideloaded onto the user's phone). Release builds, which go to
    /// TestFlight, leave the private framework out entirely: the tool isn't offered and the
    /// framework's name isn't in the binary, since App Store Connect rejects private APIs.
    #if DEBUG
    static let available = true
    #else
    static let available = false
    #endif

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let send: SendCommand? = {
        #if !DEBUG
        return nil
        #else
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
        #endif
    }()

    static func run(_ command: Command) {
        guard let send else { return VoiceSessionController.appLog("media_control unavailable") }
        let accepted = send(command.code, nil)
        VoiceSessionController.appLog("media_control \(command.rawValue) accepted=\(accepted)")
    }
}
