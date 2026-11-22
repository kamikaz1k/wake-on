import SwiftUI

/// Lobby's chat view (Wake On's chat logs, and Chat Lab's "Ours" page), implementing shadcn's "What Makes a Great Streaming Chat
/// Experience" rules (MessageScroller docs). The library pages show their libraries out of the
/// box; this view is the reference they are compared against.
///
/// How the rules map:
/// - Turns: rows are grouped into turns, each starting at one of your messages (the anchor).
/// - A4/A5/A6: the last turn is at least (viewport − 64 pt) tall. Scrolling to the bottom then
///   puts the new anchor 64 pt below the top, with a slice of the previous turn above it, and
///   the reply grows into the empty space without moving anything.
/// - A1/A2/A3/A7: we follow the live edge only while `following`. Any drag or tap stops it;
///   ending a scroll at the bottom resumes it. New turns don't move a reader who is away.
/// - A8/A9: a jump button appears when away, saying what's happening below.
/// - A10: an outline of turns with search; tapping one jumps there.
/// - A11: a transcript that arrives all at once (a saved call) opens at your last message,
///   hidden until positioned so there's no visible jump.
/// - A12/B4: `scrollPosition` with `scrollTargetLayout` keeps the turn you're reading in place
///   when rows are inserted or resized above it.
/// - A15: VoiceOver announces each finished Lobby reply once, not token by token.
/// - D1: a "Lobby" label starts each run of Lobby messages. D7: edge fades when scrollable.
/// Lobby's text uses MarkdownView (via `SizedMarkdown`) for lists, tables and code.
struct ChatTurn: Identifiable {
    let id: String
    var items: [ChatItem]
    var isAnchored: Bool { items.first?.isUser == true }
}

@available(iOS 18.0, *)
struct ChatTranscriptView: View {
    let items: [ChatItem]
    let call: ChatCallState
    /// The call phase line (Live, Ended) and the Turns button above the transcript.
    var showsHeader = true
    private var status: String? { call.status }

    static let peek: CGFloat = 64
    static let edge: CGFloat = 32
    private let padding: CGFloat = 16

    struct Metrics: Equatable {
        var contentHeight: CGFloat = 0
        var fromTop: CGFloat = 0
        var fromBottom: CGFloat = 0
        var viewport: CGFloat = 0
    }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var dragging = false
    @State private var metrics = Metrics()
    @State private var unseen = 0
    @State private var ready = false
    @State private var visibleTurns: [String] = []
    @State private var showOutline = false
    @State private var announced: Set<String> = []

    private var turns: [ChatTurn] {
        var result: [ChatTurn] = []
        for item in items {
            if item.isUser || result.isEmpty {
                result.append(ChatTurn(id: item.id, items: [item]))
            } else {
                result[result.count - 1].items.append(item)
            }
        }
        return result
    }

    private var lobbyTalking: Bool {
        items.contains { if case .message(.lobby, _, .streaming) = $0.kind { true } else { false } }
    }

    var body: some View {
        let turns = turns
        VStack(spacing: 0) {
            if showsHeader {
                ChatCallHeader(call: call).overlay(alignment: .trailing) { outlineButton }
            }
            scroller(turns)
        }
    }

    private func scroller(_ turns: [ChatTurn]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let isLast = index == turns.count - 1
                    TurnView(turn: turn, status: isLast ? status : nil)
                        // Room for the newest turn to read from its start (A4–A6).
                        .frame(minHeight: isLast ? max(0, metrics.viewport - Self.peek - padding) : nil, alignment: .top)
                        .id(turn.id)
                }
            }
            .scrollTargetLayout()
            .padding(padding)
        }
        .scrollPosition($position)
        .opacity(ready || items.isEmpty ? 1 : 0)
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(contentHeight: geometry.contentSize.height,
                    fromTop: geometry.visibleRect.minY,
                    fromBottom: geometry.contentSize.height - geometry.visibleRect.maxY,
                    viewport: geometry.containerSize.height)
        } action: { old, new in
            metrics = new
            // Follow the live edge while the reader is following (A2).
            if following, !dragging, new.contentHeight != old.contentHeight { position.scrollTo(edge: .bottom) }
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                dragging = true
                following = false // moving is a signal: stop following (A1)
            case .idle:
                if dragging {
                    dragging = false
                    // Coming to rest at the live edge resumes following.
                    if metrics.fromBottom < Self.edge { following = true; unseen = 0 }
                }
            default:
                break
            }
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { visibleTurns = $0 }
        // Tapping (expand a tool row, open a link, select) is a signal too (A3).
        .simultaneousGesture(TapGesture().onEnded { if metrics.fromBottom > 1 || lobbyTalking { following = false } })
        .mask { edgeFades }
        .overlay(alignment: .bottom) { jumpButton }
        .sheet(isPresented: $showOutline) {
            ChatOutline(turns: turns, current: currentTurn(turns)) { id in
                showOutline = false
                following = false
                withAnimation(.smooth) { position.scrollTo(id: id, anchor: .top) }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: items.count) { old, new in itemsCountChanged(from: old, to: new, turns: turns) }
        // The pager can recreate this page with messages already there; its state starts
        // fresh (hidden), and no count change will arrive to reveal it. Position and show now.
        .onAppear {
            guard !ready, !items.isEmpty else { return }
            itemsCountChanged(from: 0, to: items.count, turns: turns)
        }
        .onChange(of: turns.last?.id) { _, _ in
            // A new turn: anchor it near the top, but only if the reader is following (A4, A7).
            guard ready, turns.last?.isAnchored == true else { return }
            if following {
                withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: items) { _, items in announceFinishedReplies(items) }
    }

    private func itemsCountChanged(from old: Int, to new: Int, turns: [ChatTurn]) {
        if new == 0 { // replay restarted
            following = true; unseen = 0; ready = false; announced = []
            return
        }
        if old == 0 {
            // Arrived all at once (a saved call or earlier history): open at your last message
            // with its reply below, not the very bottom (A11). Hidden until positioned.
            if new > 3, let lastAnchor = turns.last(where: \.isAnchored)?.id {
                DispatchQueue.main.async {
                    position.scrollTo(id: lastAnchor, anchor: .top)
                    DispatchQueue.main.async {
                        following = metrics.fromBottom < Self.edge
                        ready = true
                    }
                }
            } else {
                position.scrollTo(edge: .bottom)
                ready = true
            }
            return
        }
        if !following, new > old { unseen += new - old }
    }

    private func currentTurn(_ turns: [ChatTurn]) -> String? {
        turns.last { visibleTurns.contains($0.id) && $0.isAnchored }?.id ?? visibleTurns.first
    }

    private func announceFinishedReplies(_ items: [ChatItem]) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        for item in items where !announced.contains(item.id) {
            if case let .message(.lobby, text, state) = item.kind, state != .streaming {
                announced.insert(item.id)
                AccessibilityNotification.Announcement("Lobby: \(text)").post()
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder private var jumpButton: some View {
        if !following, metrics.fromBottom > Self.edge {
            Button {
                following = true
                unseen = 0
                withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
            } label: {
                Label(lobbyTalking ? "Lobby is talking" : unseen > 0 ? "\(unseen) new" : "Jump to latest",
                      systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shimmering(lobbyTalking)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("ours-jump-latest")
        }
    }

    @ViewBuilder private var outlineButton: some View {
        if turns.filter(\.isAnchored).count > 1 {
            Button { showOutline = true } label: {
                Label("Turns", systemImage: "list.bullet").font(.caption.weight(.semibold))
            }
            .padding(.horizontal)
            .accessibilityLabel("Jump to a turn")
            .accessibilityIdentifier("ours-outline")
        }
    }

    /// shadcn's `scroll-fade`: a linear fade of min(12%, 40 pt) at each edge that grows in
    /// with scroll. The top fade eases from 0 to full over the first 96 pt scrolled, the bottom
    /// one eases out over the last 96 pt (CSS `animation-range` with ease-in-out), so it never
    /// pops on.
    private var edgeFades: some View {
        let size = min(metrics.viewport * 0.12, 40)
        let top = size * Self.easeInOut(metrics.fromTop / 96)
        let bottom = size * Self.easeInOut(metrics.fromBottom / 96)
        return VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
        }
    }

    /// CSS ease-in-out (cubic-bezier 0.42, 0, 0.58, 1), close enough as smoothstep.
    private static func easeInOut(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// One turn: your message, then everything until your next message.
private struct TurnView: View {
    let turn: ChatTurn
    let status: String?

    var body: some View {
        let segments = ChatToolGrouping.segments(turn.items, live: status != nil)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment.content {
                case let .item(index):
                    let item = turn.items[index]
                    let startsLobbyRun = item.speaker == .lobby
                        && (index == 0 || turn.items[index - 1].speaker != .lobby)
                    PlainRow(item: item, showName: startsLobbyRun)
                case let .tools(tools, finished):
                    ChatToolChain(tools: tools, finished: finished).padding(.horizontal, 4)
                }
            }
            // A running chain already shows what Lobby is doing; the status line would repeat it.
            if let status, !ChatToolGrouping.endsWithRunningChain(segments) {
                ChatStatusLine(text: status).padding(.leading, 4)
            }
        }
    }
}

/// Runs of plain tool calls (not visuals or maps, which show their own content) become one
/// chain. A chain is finished once all its steps are and the turn has moved on past it
/// (something follows it, or the turn isn't live).
enum ChatToolGrouping {
    struct Segment: Identifiable {
        enum Content { case item(Int), tools([ChatItem.Tool], finished: Bool) }
        let id: String
        let content: Content
    }

    static func isChainable(_ item: ChatItem) -> ChatItem.Tool? {
        guard case let .tool(tool) = item.kind, tool.visual == nil, tool.place == nil else { return nil }
        return tool
    }

    static func endsWithRunningChain(_ segments: [Segment]) -> Bool {
        if case let .tools(_, finished) = segments.last?.content { return !finished }
        return false
    }

    static func segments(_ items: [ChatItem], live: Bool) -> [Segment] {
        var result: [Segment] = []
        var index = 0
        while index < items.count {
            guard isChainable(items[index]) != nil else {
                result.append(Segment(id: items[index].id, content: .item(index)))
                index += 1
                continue
            }
            let start = index
            var tools: [ChatItem.Tool] = []
            while index < items.count, let tool = isChainable(items[index]) {
                tools.append(tool)
                index += 1
            }
            let allDone = tools.allSatisfy { $0.state == .done || $0.state == .failed }
            let movedOn = index < items.count || !live
            // Keyed by its first step, so the chain keeps its state as steps are added.
            result.append(Segment(id: "chain-" + items[start].id, content: .tools(tools, finished: allDone && movedOn)))
        }
        return result
    }

    /// For chat libraries that take one flat list (Chat Lab's exyte and ConversationKit pages):
    /// each item, or a whole tool chain in place of its run of tool calls.
    enum Row: Identifiable, Equatable {
        case item(ChatItem)
        /// `time` is the first call's.
        case chain(id: String, tools: [ChatItem.Tool], finished: Bool, time: Date)

        var id: String {
            switch self {
            case let .item(item): item.id
            case let .chain(id, _, _, _): id
            }
        }
    }

    static func rows(_ items: [ChatItem], live: Bool) -> [Row] {
        segments(items, live: live).map { segment in
            switch segment.content {
            case let .item(index): .item(items[index])
            case let .tools(tools, finished):
                .chain(id: segment.id, tools: tools, finished: finished,
                       time: items.first { "chain-" + $0.id == segment.id }?.time ?? Date())
            }
        }
    }

    /// The status line repeats what a running chain shows, so it hides meanwhile.
    static func endsWithRunningChain(_ rows: [Row]) -> Bool {
        if case let .chain(_, _, finished, _) = rows.last { return !finished }
        return false
    }
}

/// Every turn, with search across all messages (A10). The current turn is checked.
private struct ChatOutline: View {
    let turns: [ChatTurn]
    let current: String?
    let jump: (String) -> Void
    @State private var query = ""

    private var results: [(turn: String, item: ChatItem)] {
        let pairs = turns.flatMap { turn in turn.items.map { (turn: turn.id, item: $0) } }
        if query.isEmpty { return pairs.filter { $0.item.isUser } }
        return pairs.filter { $0.item.speaker != nil && $0.item.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results, id: \.item.id) { result in
                Button { jump(result.turn) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.item.speaker?.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(result.item.text).lineLimit(2)
                        }
                        Spacer()
                        if result.turn == current { Image(systemName: "location.fill").foregroundStyle(.tint) }
                    }
                }
                .tint(.primary)
            }
            .searchable(text: $query, prompt: "Search this call")
            .navigationTitle("Turns")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct PlainRow: View {
    let item: ChatItem
    var showName = false

    var body: some View {
        if case let .message(speaker, text, state) = item.kind {
            VStack(alignment: speaker == .user ? .trailing : .leading, spacing: 3) {
                if showName {
                    Text("Lobby").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12) // line up with the text inside the bubble
                }
                Group {
                    if speaker == .lobby, !text.isEmpty {
                        SizedMarkdown(text: text) // full markdown: lists, tables, code (MarkdownView)
                    } else {
                        Text(Self.markdown(text.isEmpty && state == .streaming ? "…" : text))
                    }
                }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(speaker == .user ? Color.white : Color.primary)
                    .background(speaker == .user ? Color.accentColor : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
                ChatMessageFooter(item: item).padding(.horizontal, 12)
                if state != .streaming, !text.isEmpty {
                    MessageActions(text: text, canExpand: speaker == .lobby && SizedMarkdown.containsTable(text),
                                   canReport: speaker == .lobby)
                        .padding(.horizontal, 4) // icons have their own padding; text edge lines up
                }
            }
            .frame(maxWidth: .infinity, alignment: speaker == .user ? .trailing : .leading)
            .padding(speaker == .user ? .leading : .trailing, 40)
        } else {
            ChatNonMessageRow(item: item)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Actions under a finished message: Copy, Expand for wide tables, and Report on Lobby's
/// replies (App Review Guidelines 1.2 and 4.7.1: a way to report objectionable AI output).
private struct MessageActions: View {
    let text: String
    var canExpand = false
    var canReport = false
    @State private var copied = false
    @State private var expanded = false
    @State private var confirmReport = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = text
                withAnimation(.snappy) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(.snappy) { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .accessibilityIdentifier("message-copy")
            if canExpand {
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Expand")
                .accessibilityIdentifier("message-expand")
            }
            if canReport {
                Button { confirmReport = true } label: {
                    Image(systemName: "flag")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Report")
                .accessibilityIdentifier("message-report")
            }
        }
        .sheet(isPresented: $expanded) { ExpandedMessage(text: text) }
        .confirmationDialog("Report this response?", isPresented: $confirmReport, titleVisibility: .visible) {
            Button("Report") {
                UIPasteboard.general.string = text
                openURL(MessageReport.url)
            }
        } message: {
            Text(MessageReport.explanation)
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }
}

/// Where a reported Lobby reply goes: a GitHub issue form. The reply itself stays out of the
/// link (issues are public); it's copied so the reporter can choose to paste it.
enum MessageReport {
    static let explanation = "This opens a report form on GitHub, where reports are public. "
        + "The response is copied, so you can paste it in if you want to."
    static var url: URL {
        var parts = URLComponents(string: "https://github.com/kamikaz1k/wake-on/issues/new")!
        parts.queryItems = [
            URLQueryItem(name: "title", value: "Report: a Lobby response"),
            URLQueryItem(name: "labels", value: "report"),
            URLQueryItem(name: "body", value: "What was wrong with the response?\n\n"
                         + "(Optional) Paste the response here. It was copied when you tapped Report.\n"),
        ]
        return parts.url!
    }
}

/// Call phase and mute (F4), for renderers that can show something above the transcript.
struct ChatCallHeader: View {
    let call: ChatCallState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(call.phase == "Live" ? Color.green : call.phase == "Ended" ? Color.secondary : Color.orange)
                .frame(width: 7, height: 7)
            Text(call.phase)
            if call.muted { Label("Muted", systemImage: "mic.slash.fill").foregroundStyle(.red) }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal).padding(.vertical, 4)
    }
}
