import Foundation

/// The assistant's name: what the app shows, what the assistant calls itself in calls, and the
/// wake phrase ("Hey <name>"), which `WakePhrase` turns into sounds for the wake-word model.
///
/// Renaming is one value: set `nameKey` in UserDefaults (or launch with `-agentName Nova` to try
/// it) and everything that reads `Agent.name` follows, the wake word included. There's no setting
/// for it in the app yet. A few places can't follow at run time and say "Pixie" on their own:
/// Info.plist, the App Shortcut phrases (they use the app's name, also Pixie) and the server's
/// copy. The Live Activity runs in its own process and shows `defaultName`.
enum Agent {
    static let defaultName = "Pixie"
    static let nameKey = "agentName"

    static var name: String {
        let custom = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
    }

    /// What wakes the assistant, as shown to the user.
    static var wakePhrase: String { "Hey \(name)" }

    /// Speaker id for the assistant's lines in transcripts and saved chats. Stored data, so it
    /// stays the same when the name changes (it predates the rename to Pixie).
    static let speakerID = "Lobby"
}
