import Charts
import SwiftUI

/// Rows for things chat libraries don't have built in (tool calls, markers, raw events,
/// cards, live status). Each renderer places these wherever its library accepts a custom
/// view, so differences between pages come from the libraries, not from our styling.

/// One tool call on its own (Chat Lab's library pages place rows one by one): a chain of one
/// step, collapsed once it's done. Lobby's own view groups a turn's calls (`ChatToolChain`).
struct ChatToolRow: View {
    let tool: ChatItem.Tool

    var body: some View {
        ChatToolChain(tools: [tool], finished: tool.state == .done || tool.state == .failed)
    }
}

struct ChatMarkerRow: View {
    let text: String
    let style: ChatItem.MarkerStyle

    var body: some View {
        switch style {
        case .separator:
            HStack {
                VStack { Divider() }
                Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack { Divider() }
            }
        case .system, .error:
            Text(text)
                .font(.caption)
                .foregroundStyle(style == .error ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

struct ChatEventRow: View {
    let event: ChatItem.RawEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Text(event.direction.rawValue).foregroundStyle(event.direction == .sent ? Color.blue : event.direction == .app ? Color.orange : Color.purple)
                    Text(event.type)
                    Spacer()
                }
                .font(.caption.monospaced())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(event.body).font(.caption2.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatCardView: View {
    let card: ChatItem.Card

    var body: some View {
        switch card {
        case let .chart(title, points):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                Chart(Array(points.enumerated()), id: \.offset) { index, value in
                    BarMark(x: .value("Day", ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][index % 7]),
                            y: .value("Price", value))
                }
                .frame(height: 140)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        case let .image(systemName, caption):
            VStack(spacing: 6) {
                Image(systemName: systemName).font(.system(size: 64)).frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        case let .buttons(labels):
            HStack {
                ForEach(labels, id: \.self) { label in
                    Button(label) {}.buttonStyle(.bordered).font(.caption)
                }
            }
        }
    }
}

/// Small grey footer under a Lobby reply, for turn timing (E2) and the cut-off state (B3).
struct ChatMessageFooter: View {
    let item: ChatItem
    var body: some View {
        if case let .message(_, _, state) = item.kind, state == .cutOff {
            HStack(spacing: 3) { Image(systemName: "scissors"); Text("Interrupted") }.font(.caption2).foregroundStyle(.orange)
        } else if let timing = item.timing {
            Text(timing).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The live status line ("Thinking…") with a moving shimmer, like shadcn's shimmer utility.
struct ChatStatusLine: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).shimmering(true)
            .accessibilityLabel(text)
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width / 2)
                            .offset(x: phase * proxy.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
                }
        } else {
            content
        }
    }
}

/// Shared rendering for non-message rows, so each renderer only has to place it.
struct ChatNonMessageRow: View {
    let item: ChatItem
    var body: some View {
        switch item.kind {
        case .message: EmptyView()
        case let .tool(tool):
            if let visual = tool.visual { ChatVisualRow(tool: tool, visual: visual) }
            else if let place = tool.place { ChatPlaceRow(place: place) }
            else { ChatToolRow(tool: tool) }
        case let .marker(text, style): ChatMarkerRow(text: text, style: style)
        case let .event(event): ChatEventRow(event: event)
        case let .card(card): ChatCardView(card: card)
        }
    }
}
