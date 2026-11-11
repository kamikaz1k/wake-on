import SwiftUI
import ConversationKit

/// ConversationKit 0.1.1 renderer. Messages go through the library's own `ConversationView`
/// (its "push and pin" scrolling, its composer) and `MessageView` (MarkdownUI). Rows the
/// library has no notion of (tools, markers, raw events, cards) ride along as `.other`
/// messages and render with our shared rows. No scroll logic of our own on purpose.
struct ConversationKitRenderer: View {
    @ObservedObject var player: LabPlayer
    @State private var messages: [LabConvMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            // ConversationView has no header slot, so call state (F4) and the live status
            // line (B6) sit above it. Its disclaimer slot only shows after an `.other`
            // message, so it can't carry "Listening…" while you speak.
            LabCallHeader(call: player.call)
            // Fixed-height slot, so the transcript doesn't shift when the status comes and goes.
            ZStack(alignment: .leading) {
                Text(" ").font(.footnote).hidden()
                if let status = player.call.status { LabStatusLine(text: status) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.bottom, 4)
            ConversationView(messages: $messages) { message in
                if let item = message.item, item.speaker == nil {
                    LabNonMessageRow(item: item)
                } else {
                    MessageView(message: message.content, imageURL: message.imageURL,
                                participant: message.participant, error: message.error)
                    if message.participant == .user, let item = message.item {
                        // Message actions only exist for `.other`, so a user footer goes here.
                        LabMessageFooter(item: item).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            // Library hook for the row under an AI message: Lobby's timing or "Interrupted".
            .messageActions { message in
                if let message = message as? LabConvMessage, let item = message.item, item.speaker == .lobby {
                    LabMessageFooter(item: item).padding(.leading, 34)
                }
            }
            .disableAttachments()
            // The composer can't be hidden (F1); typed messages are dropped, the voice
            // transcript is the only source.
            .onSendMessage { _ in }
        }
        .onAppear(perform: sync)
        .onChange(of: player.revision) { sync() }
    }

    private func sync() {
        messages = player.items.map(LabConvMessage.init(item:))
    }
}

/// ConversationKit's `Message` carrying a lab row. Equality includes the text and the whole
/// row, so streaming deltas and tool state changes re-render.
struct LabConvMessage: Message {
    let id: String
    var content: String?
    let imageURL: String? = nil
    let participant: Participant
    let error: (any Error)? = nil
    var item: LabItem?

    init(item: LabItem) {
        id = item.id
        participant = item.speaker == .user ? .user : .other
        if case let .message(_, text, _) = item.kind {
            content = text
        } else {
            content = item.text
        }
        self.item = item
    }

    /// Used by the composer when someone types; not part of the replay.
    init(content: String?, imageURL: String?, participant: Participant) {
        id = UUID().uuidString
        self.content = content
        self.participant = participant
        item = nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.participant == rhs.participant && lhs.item == rhs.item
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(content)
    }
}
