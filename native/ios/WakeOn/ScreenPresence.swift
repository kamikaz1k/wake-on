import UIKit

/// Whether the user can see Pixie during a call. In view, visuals and maps are worth showing
/// unasked; away (phone locked, or Pixie in the background, as with most Hey Pixie calls),
/// they wait unseen in the chat, so Pixie answers in speech instead.
///
/// The app tells both models once the call starts and whenever it changes: the backend gets
/// its instructions updated (`session.update`), the voice model gets quiet context
/// (`session.thinking.append`).
enum ScreenPresence: String {
    case inView = "in_view"
    case away

    /// Background means locked or another app in front. Inactive (an Action Button launch
    /// still coming forward, Control Center pulled down) counts as in view.
    @MainActor static var current: ScreenPresence {
        UIApplication.shared.applicationState == .background ? .away : .inView
    }

    /// Always in the backend's instructions; the state line is added after it.
    static let backendGuidance = """
    The last line of these instructions, starting "Screen:", says whether the user can see \
    their screen. When they can, lean on visuals: for a place, options to compare, a list, \
    numbers over time, a schedule or steps, show it (open_map with mode show for a place, \
    show_visual for the rest) along with a short spoken answer, even if they didn't ask. When \
    they can't, answer fully in words, and only show something if they ask to see it; it waits \
    in the app for later, so say so. With no Screen line, show things only when asked.
    """

    var backendLine: String {
        switch self {
        case .inView: "Screen: the user is looking at Pixie now."
        case .away: "Screen: the user can't see the screen right now (the phone is locked or Pixie is in the background)."
        }
    }

    /// For the voice model, which decides what to delegate and how much to say.
    var thinking: String {
        switch self {
        case .inView:
            "The user can now see Pixie's screen, where charts, tables and maps appear. Delegate questions that a chart, list or map would answer well, and keep the spoken answer short when something is on screen."
        case .away:
            "The user can't see the screen right now (the phone is locked or Pixie is in the background). Answer fully in speech; anything shown waits in the app for later."
        }
    }

    /// Added to show_visual's and open_map show's result when the user can't see it.
    static let awayResult = " The user can't see the screen right now: say the key points aloud and that it's waiting in the app."
}
