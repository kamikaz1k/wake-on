import Charts
import SwiftUI

/// Rows for things chat libraries don't have built in (tool calls, markers, raw events,
/// cards, live status). Each renderer places these wherever its library accepts a custom
/// view, so differences between pages come from the libraries, not from our styling.

struct LabToolRow: View {
    let tool: LabItem.Tool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon
                    Text(title).font(.subheadline.weight(.medium))
                        .shimmering(tool.state == .running || tool.state == .requested)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                LabeledContent("Arguments") { Text(tool.arguments).font(.caption.monospaced()).textSelection(.enabled) }
                    .font(.caption)
                if let result = tool.result {
                    LabeledContent("Result") { Text(result).font(.caption.monospaced()).textSelection(.enabled) }
                        .font(.caption)
                }
            }
            if !tool.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tool.sources, id: \.self) { source in
                            if let url = URL(string: source.url) {
                                Link(destination: url) {
                                    Label(source.title, systemImage: "link").font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let name = tool.name.replacingOccurrences(of: "_", with: " ")
        switch tool.state {
        case .requested: return "Asking to \(name)…"
        case .running: return "Running \(name)…"
        case .done: return "\(name.capitalized(with: nil)) · done"
        case .failed: return "\(name.capitalized(with: nil)) · failed"
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch tool.state {
        case .requested: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct LabMarkerRow: View {
    let text: String
    let style: LabItem.MarkerStyle

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

struct LabEventRow: View {
    let event: LabItem.RawEvent
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

struct LabCardView: View {
    let card: LabItem.Card

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
struct LabMessageFooter: View {
    let item: LabItem
    var body: some View {
        if case let .message(_, _, state) = item.kind, state == .cutOff {
            HStack(spacing: 3) { Image(systemName: "scissors"); Text("Interrupted") }.font(.caption2).foregroundStyle(.orange)
        } else if let timing = item.timing {
            Text(timing).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The live status line ("Thinking…") with a moving shimmer, like shadcn's shimmer utility.
struct LabStatusLine: View {
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
struct LabNonMessageRow: View {
    let item: LabItem
    var body: some View {
        switch item.kind {
        case .message: EmptyView()
        case let .tool(tool): LabToolRow(tool: tool)
        case let .marker(text, style): LabMarkerRow(text: text, style: style)
        case let .event(event): LabEventRow(event: event)
        case let .card(card): LabCardView(card: card)
        }
    }
}
