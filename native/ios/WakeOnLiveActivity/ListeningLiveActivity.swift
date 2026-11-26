import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WakeOnLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
        if #available(iOS 26.0, *) { AlarmLiveActivity() }
    }
}

/// The listener's Live Activity: the sky orb, calm while listening and bright once it hears
/// "Hey Pixie" or a conversation is on.
struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningActivityAttributes.self) { context in
            LockScreenView(look: Look(context))
                .activityBackgroundTint(Look.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let look = Look(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbView(look: look, size: 52).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(look.title).font(.headline).foregroundStyle(.white)
                        DetailText(look: look)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                OrbView(look: look, size: 24)
            } compactTrailing: {
                CompactTrailing(look: look)
            } minimal: {
                OrbView(look: look, size: 24)
            }
            .widgetURL(URL(string: "wakeon://open"))
            .keylineTint(look.tint)
        }
    }
}

/// Everything the views need, from the activity's state.
struct Look {
    typealias Mode = ListeningActivityAttributes.ContentState.Mode
    static let background = Color(red: 0.02, green: 0.03, blue: 0.07)
    let mode: Mode
    let since: Date
    /// The app stopped refreshing the activity: it was closed or the phone restarted.
    let stale: Bool

    init(_ context: ActivityViewContext<ListeningActivityAttributes>) {
        mode = context.state.mode
        since = context.state.since
        stale = context.isStale
    }

    var bright: Bool { !stale && (mode == .heard || mode == .talking) }
    var dimmed: Bool { stale || mode == .paused }
    var tint: Color { dimmed ? .gray : Color(red: 0.35, green: 0.65, blue: 1.0) }

    var title: String {
        if stale { return "Not listening" }
        switch mode {
        case .listening: return "Listening for \(Agent.wakePhrase)"
        case .heard: return "Heard you"
        case .talking: return "Talking with \(Agent.name)"
        case .paused: return "Listening paused"
        }
    }

    var detail: String {
        if stale { return "Open Pixie to listen again" }
        switch mode {
        case .listening: return "Say “\(Agent.wakePhrase)” to talk"
        case .heard: return "Connecting…"
        case .talking: return ""
        case .paused: return "Another app has the microphone"
        }
    }
}

struct OrbView: View {
    let look: Look
    let size: CGFloat
    var body: some View {
        Image(look.bright ? "OrbBright" : "OrbCalm")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // Calm is a little smaller, so the orb grows when it hears "Hey Pixie".
            .scaleEffect(look.bright ? 1 : 0.84)
            .saturation(look.dimmed ? 0 : 1)
            .opacity(look.dimmed ? 0.6 : 1)
            .accessibilityHidden(true)
    }
}

/// The subtitle; a running call timer while talking.
struct DetailText: View {
    let look: Look
    var body: some View {
        Group {
            if look.mode == .talking && !look.stale {
                Text(look.since, style: .timer).monospacedDigit()
            } else {
                Text(look.detail)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.65))
        .lineLimit(1)
    }
}

struct CompactTrailing: View {
    let look: Look
    var body: some View {
        if look.stale {
            Image(systemName: "mic.slash").foregroundStyle(.gray)
        } else {
            switch look.mode {
            case .listening:
                Image(systemName: "waveform").foregroundStyle(look.tint)
            case .heard:
                Text("Hi").font(.caption.weight(.semibold)).foregroundStyle(look.tint)
            case .talking:
                Text(timerInterval: look.since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(look.tint)
                    .frame(maxWidth: 44)
            case .paused:
                Image(systemName: "pause.fill").foregroundStyle(.orange)
            }
        }
    }
}

struct LockScreenView: View {
    let look: Look
    var body: some View {
        HStack(spacing: 14) {
            OrbView(look: look, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.headline).foregroundStyle(.white)
                DetailText(look: look)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
