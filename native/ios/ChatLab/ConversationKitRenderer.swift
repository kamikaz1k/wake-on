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
            ChatCallHeader(call: player.call)
            // Fixed-height slot, so the transcript doesn't shift when the status comes and goes.
            ZStack(alignment: .leading) {
                Text(" ").font(.footnote).hidden()
                // Hidden while a tool chain runs: the chain says the same (as in Pixie).
                if let status = player.call.status, !ChatToolGrouping.endsWithRunningChain(rows) {
                    ChatStatusLine(text: status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.bottom, 4)
            ConversationView(messages: $messages) { message in
                if let chain = message.chain {
                    ChatToolChain(tools: chain.tools, finished: chain.finished)
                } else if let item = message.item, item.speaker == nil {
                    ChatNonMessageRow(item: item)
                } else {
                    MessageView(message: message.content, imageURL: message.imageURL,
                                participant: message.participant, error: message.error)
                    if message.participant == .user, let item = message.item {
                        // Message actions only exist for `.other`, so a user footer goes here.
                        ChatMessageFooter(item: item).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            // Library hook for the row under an AI message: Lobby's timing or "Interrupted".
            .messageActions { message in
                if let message = message as? LabConvMessage, let item = message.item, item.speaker == .lobby {
                    ChatMessageFooter(item: item).padding(.leading, 34)
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

    private var rows: [ChatToolGrouping.Row] {
        ChatToolGrouping.rows(player.items, live: player.call.status != nil)
    }

    private func sync() {
        messages = rows.map(LabConvMessage.init(row:))
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
    var item: ChatItem?
    /// A run of tool calls drawn as Pixie's chain.
    var chain: (tools: [ChatItem.Tool], finished: Bool)?

    init(row: ChatToolGrouping.Row) {
        switch row {
        case let .item(item): self.init(item: item)
        case let .chain(id, tools, finished, _): self.init(chainID: id, tools: tools, finished: finished)
        }
    }

    private init(chainID: String, tools: [ChatItem.Tool], finished: Bool) {
        id = chainID
        participant = .other
        chain = (tools, finished)
    }

    init(item: ChatItem) {
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
            && lhs.chain?.tools == rhs.chain?.tools && lhs.chain?.finished == rhs.chain?.finished
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(content)
    }
}
