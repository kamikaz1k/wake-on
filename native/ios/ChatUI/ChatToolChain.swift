import SwiftUI

/// A turn's tool calls as one quiet chain, like Claude's: while the turn runs, each step is a
/// line of small grey text on a thin connecting line, the current step shimmering. Once the
/// turn is done (Pixie replied, or the call is saved) it collapses into one summary line
/// ("Searched the web, opened Spotify ›") that opens the chain again on tap.
struct ChatToolChain: View {
    let tools: [ChatItem.Tool]
    /// The turn has moved on: collapse to the summary.
    let finished: Bool
    @State private var expanded = Self.debugStepDetails
    /// Follows `finished` one update later, inside an animation: see `onChange(of: finished)`.
    @State private var collapsed: Bool
    @State private var stepsHeight: CGFloat = 0
    @State private var summaryHeight: CGFloat = 0
    @Environment(\.chatAnimatedResize) private var announceResize

    static let motion = Animation.snappy(duration: 0.3)
    /// `-tool-step-details`: chains start open and their first step's details toggle every 2 s.
    static let debugStepDetails: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-tool-step-details")
        #else
        false
        #endif
    }()
    /// Between the summary and the open steps.
    static let gap: CGFloat = 6

    init(tools: [ChatItem.Tool], finished: Bool) {
        self.tools = tools
        self.finished = finished
        _collapsed = State(initialValue: finished)
    }

    private var showsSteps: Bool { !collapsed || expanded }

    var body: some View {
        // Both rows are always laid out, each in a frame clipped between two concrete heights:
        // the summary grows from 0 as the steps shrink, so they never overlap or fade (see the
        // animation-engineering skill, principles 1 and 4). Inserting the summary instead
        // pushed the shrinking steps under it for a couple of frames.
        //
        // Every height change runs inside `withAnimation` (`animate`), never a scoped
        // `.animation(_:value:)`: the scoped one animated only this view, so the rows around it
        // and the transcript's scroll jumped to their final places in one frame while the
        // chain was still opening (principle 8, FLIP).
        VStack(alignment: .leading, spacing: 0) {
            // The gap under the summary is part of its animated frame, not padding inside the
            // measured row: as padding, the 6 pt was measured one update late, outside the
            // animation, and the rows below jumped 6 pt in the first frame of every toggle.
            Button { toggle() } label: { summary }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
                .frame(height: collapsed ? summaryHeight + (expanded ? Self.gap : 0) : 0, alignment: .top)
                .clipped()
                .disabled(!collapsed)
                .accessibilityHidden(!collapsed)
                .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")
                .accessibilityIdentifier("tool-chain-summary")
            steps
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // A new step, or a step's details: grow with everything around the chain.
                    // The first measurement just appears (the chain itself was just inserted).
                    if showsSteps, stepsHeight > 0 { animate { stepsHeight = height } } else { stepsHeight = height }
                }
                .frame(height: showsSteps ? stepsHeight : 0, alignment: .top)
                .clipped()
                .accessibilityHidden(!showsSteps)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: finished) { _, now in
            // The row that finished the chain (Pixie's reply) is inserted in this update. Let it
            // lay out below the open steps first, then collapse: it rises with the steps
            // instead of starting at its final place over them.
            Task { @MainActor in animate { collapsed = now } }
        }
        #if DEBUG
        // `-tool-chain-toggle`: tap every finished chain's summary every 2 s (animation checks).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-tool-chain-toggle") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if finished { print("ACTION \(CACurrentMediaTime()) tool-chain toggle"); toggle() }
            }
        }
        #endif
    }

    private func toggle() {
        animate { expanded.toggle() }
    }

    /// One animated transaction for this chain, the rows after it and the transcript's scroll.
    private func animate(_ change: () -> Void) {
        announceResize(Self.motion)
        withAnimation(Self.motion, change)
    }

    private var summary: some View {
        HStack(spacing: 5) {
            if tools.contains(where: { $0.state == .failed }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
            }
            Text(ChatToolSteps.summary(tools)).lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                ChatToolStep(tool: tool, isLast: index == tools.count - 1, isFirst: index == 0)
            }
        }
    }
}

/// One step: its icon on the chain's line, what it did, and its links. Tap for the details.
private struct ChatToolStep: View {
    let tool: ChatItem.Tool
    let isLast: Bool
    var isFirst = false
    @State private var details = false
    @Environment(\.chatAnimatedResize) private var announceResize

    private var active: Bool { tool.state == .requested || tool.state == .running }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                Image(systemName: ChatToolSteps.icon(tool.name))
                    .imageScale(.small)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(tool.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if !isLast {
                    Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { toggleDetails() } label: {
                    Text(ChatToolSteps.label(tool))
                        .multilineTextAlignment(.leading)
                        .shimmering(active)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if details {
                    Group {
                        if !tool.arguments.isEmpty { Text(tool.arguments) }
                        if let result = tool.result { Text(result) }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                }
                if let page = tool.page, let url = URL(string: page.url) {
                    ChatPageLink(title: page.title, url: url)
                }
                if !tool.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tool.sources, id: \.self) { source in
                                if let url = URL(string: source.url) {
                                    Link(destination: url) {
                                        Label(source.title, systemImage: "link").font(.caption2)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(.fill.tertiary, in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
        #if DEBUG
        .task {
            guard isFirst, ChatToolChain.debugStepDetails else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                print("ACTION \(CACurrentMediaTime()) step-details")
                toggleDetails()
            }
        }
        #endif
    }

    /// Inside one transaction with the rows below, the chain's height and the transcript's
    /// scroll: toggled bare, the details appeared at once and the rows below jumped (2026-11-27).
    private func toggleDetails() {
        announceResize(ChatToolChain.motion)
        withAnimation(ChatToolChain.motion) { details.toggle() }
    }
}

/// Words and icons for tool steps. Present tense while running ("Searching …"), past once
/// done ("Searched …").
enum ChatToolSteps {
    static func icon(_ name: String) -> String {
        switch name {
        case "web_search": "magnifyingglass"
        case "play_spotify", "open_in_spotify": "music.note"
        case "play_youtube", "open_in_youtube": "play.rectangle"
        case "open_map", "open_in_google_maps": "map"
        case "control_media", "media_control": "playpause"
        case "browser": "globe"
        case "save_note": "note.text"
        case "remember", "recall": "brain"
        case "set_volume": "speaker.wave.2"
        case "get_location": "location"
        case "send_feedback": "envelope"
        case "show_markdown": "doc.text"
        case "alarms": "alarm"
        case "calendar": "calendar"
        case "reminders": "checklist"
        case "mini_apps": "square.grid.2x2"
        default: "wrench.and.screwdriver"
        }
    }

    static func label(_ tool: ChatItem.Tool) -> String {
        let done = tool.state == .done || tool.state == .failed
        let args = arguments(tool.arguments)
        let firstLine = tool.arguments.split(separator: "\n").first.map(String.init) ?? ""
        func quoted(_ key: String) -> String? {
            (args[key] as? String).flatMap { $0.isEmpty ? nil : "“\($0)”" }
        }
        let text: String = switch tool.name {
        case "web_search":
            quoted("query").map { done ? "Searched \($0)" : "Searching \($0)" } ?? (done ? "Searched the web" : "Searching the web")
        case "play_spotify":
            (args["title"] as? String).map { done ? "Picked \($0)" : "Finding \($0)" } ?? (done ? "Picked a song" : "Finding a song")
        case "play_youtube":
            (args["title"] as? String).map { done ? "Picked \($0)" : "Finding \($0)" } ?? (done ? "Picked a video" : "Finding a video")
        case "open_in_spotify": done ? "Opened \(firstLine) in Spotify" : "Opening Spotify"
        case "open_in_youtube": done ? "Opened \(firstLine) in YouTube" : "Opening YouTube"
        case "open_map":
            (args["place"] as? String).map { done ? "Found \($0)" : "Finding \($0)" } ?? (done ? "Found the place" : "Finding the place")
        case "open_in_google_maps": done ? "Opened \(firstLine) in Google Maps" : "Opening Google Maps"
        case "control_media", "media_control":
            ((args["action"] as? String) ?? firstLine).isEmpty ? (done ? "Controlled playback" : "Controlling playback")
                : (done ? "Sent \((args["action"] as? String) ?? firstLine)" : "Sending \((args["action"] as? String) ?? firstLine)")
        case "browser":
            if done, args["action"] as? String == "open", let page = tool.page, !page.title.isEmpty { "Opened \(page.title)" }
            else { browser(args["action"] as? String ?? "", args["text"] as? String ?? "", done: done) }
        case "save_note":
            (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                .map { done ? "Added to \($0)" : "Adding to \($0)" } ?? (done ? "Saved a note" : "Saving a note")
        case "remember":
            quoted("note").map { done ? "Remembered \($0)" : "Remembering \($0)" } ?? (done ? "Remembered" : "Remembering")
        case "recall":
            quoted("query").map { done ? "Recalled \($0)" : "Recalling \($0)" } ?? (done ? "Searched memory" : "Searching memory")
        case "get_location": done ? "Checked your location" : "Checking your location"
        case "send_feedback": done ? "Sent feedback" : "Sending feedback"
        case "alarms": alarms(args, done: done)
        case "calendar":
            switch args["action"] as? String ?? "" {
            case "add": quoted("title").map { done ? "Added \($0) to your calendar" : "Adding \($0) to your calendar" } ?? (done ? "Added an event" : "Adding an event")
            case "delete": done ? "Deleted an event" : "Deleting an event"
            default: done ? "Checked your calendar" : "Checking your calendar"
            }
        case "reminders":
            switch args["action"] as? String ?? "" {
            case "add": quoted("title").map { done ? "Added reminder \($0)" : "Adding reminder \($0)" } ?? (done ? "Added a reminder" : "Adding a reminder")
            case "complete": done ? "Completed a reminder" : "Completing a reminder"
            default: done ? "Checked your reminders" : "Checking your reminders"
            }
        case "mini_apps":
            switch args["action"] as? String ?? "" {
            case "save": done ? "Saved to My Apps" : "Saving to My Apps"
            case "open": done ? "Opened an app" : "Opening an app"
            case "update": done ? "Changed an app" : "Changing an app"
            default: done ? "Checked your apps" : "Checking your apps"
            }
        default:
            done ? readable(tool.name).capitalizedFirst : "Running \(readable(tool.name))"
        }
        return tool.state == .failed ? text + " (failed)" : text
    }

    /// One line for a finished chain: what was done, each kind once, in order.
    static func summary(_ tools: [ChatItem.Tool]) -> String {
        var parts: [String] = []
        for tool in tools {
            let part: String = switch tool.name {
            case "web_search": "searched the web"
            case "play_spotify", "open_in_spotify": "opened Spotify"
            case "play_youtube", "open_in_youtube": "opened YouTube"
            case "open_map", "open_in_google_maps": "opened Maps"
            case "control_media", "media_control": "controlled playback"
            case "browser":
                // The page it ended on, so the folded chain says where it went.
                tools.last { $0.name == "browser" && $0.page != nil }?.page.map { "opened \($0.title)" } ?? "used the browser"
            case "save_note": "saved a note"
            case "remember": "remembered"
            case "recall": "searched memory"
            case "get_location": "checked your location"
            case "send_feedback": "sent feedback"
            case "alarms": "alarms"
            case "calendar": "used your calendar"
            case "reminders": "used your reminders"
            case "mini_apps": "used your apps"
            default: readable(tool.name)
            }
            if !parts.contains(part) { parts.append(part) }
        }
        let shown = parts.prefix(2).joined(separator: ", ")
        let more = parts.count > 2 ? " and \(parts.count - 2) more" : ""
        return (shown + more).capitalizedFirst
    }

    private static func alarms(_ args: [String: Any], done: Bool) -> String {
        let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : " “\($0)”" } ?? ""
        return switch args["action"] as? String ?? "" {
        case "set_alarm": (done ? "Set an alarm" : "Setting an alarm") + ((args["time"] as? String).map { " for \($0)" } ?? "") + label
        case "set_timer": (done ? "Set a timer" : "Setting a timer") + label
        case "cancel": done ? "Cancelled an alarm" : "Cancelling an alarm"
        default: done ? "Checked your alarms" : "Checking your alarms"
        }
    }

    private static func browser(_ action: String, _ text: String, done: Bool) -> String {
        let quoted = "“\(text)”"
        return switch action {
        case "open": done ? "Opened \(text)" : "Opening \(text)"
        case "search": done ? "Searched the page for \(quoted)" : "Searching the page for \(quoted)"
        case "find": done ? "Found \(quoted)" : "Finding \(quoted)"
        case "click": done ? "Tapped \(quoted)" : "Tapping \(quoted)"
        case "scroll": done ? "Scrolled \(text.isEmpty ? "down" : text)" : "Scrolling \(text.isEmpty ? "down" : text)"
        case "read": done ? "Read the page" : "Reading the page"
        case "close": done ? "Closed the browser" : "Closing the browser"
        default: done ? "Used the browser" : "Using the browser"
        }
    }

    private static func arguments(_ text: String) -> [String: Any] {
        (text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static func readable(_ name: String) -> String { name.replacingOccurrences(of: "_", with: " ") }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
