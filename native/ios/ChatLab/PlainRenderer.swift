import SwiftUI

/// Baseline: what we get with no library. ScrollView + LazyVStack anchored to the bottom,
/// SwiftUI's inline-only markdown, and our shared rows. No extra scroll logic on purpose,
/// so its gaps show what a library has to add.
struct PlainRenderer: View {
    @ObservedObject var player: LabPlayer

    var body: some View {
        VStack(spacing: 0) {
            LabCallHeader(call: player.call)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(player.items) { item in
                        PlainRow(item: item)
                            .id(item.id)
                    }
                    if let status = player.call.status {
                        LabStatusLine(text: status).padding(.leading, 4)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

private struct PlainRow: View {
    let item: LabItem

    var body: some View {
        if case let .message(speaker, text, state) = item.kind {
            VStack(alignment: speaker == .user ? .trailing : .leading, spacing: 3) {
                Text(Self.markdown(text.isEmpty && state == .streaming ? "…" : text))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(speaker == .user ? Color.white : Color.primary)
                    .background(speaker == .user ? Color.accentColor : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
                LabMessageFooter(item: item)
            }
            .frame(maxWidth: .infinity, alignment: speaker == .user ? .trailing : .leading)
            .padding(speaker == .user ? .leading : .trailing, 40)
        } else {
            LabNonMessageRow(item: item)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Call phase and mute (F4), for renderers that can show something above the transcript.
struct LabCallHeader: View {
    let call: LabCallState
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
