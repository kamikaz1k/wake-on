import ExyteChat
import MarkdownView
import SwiftUI

/// exyte/Chat 3.3.7 + MarkdownView 3.9.1. Each ChatItem becomes an exyte `Message`:
/// you are the current user, Pixie is another user, and non-message rows come from a
/// system user and are drawn by `messageBuilder` with our shared rows. Scrolling, grouping,
/// date headers and the scroll-to-bottom button are exyte's own; no extra scroll logic.
struct ExyteRenderer: View {
    @ObservedObject var player: LabPlayer
    /// "-lab-scroll-top N" scrolls to the oldest message after N s (reproduces scrolling to
    /// the top without touch).
    @State private var scrollTo: ScrollToParams?

    private static let you = User(id: "you", name: "You", avatarURL: nil, isCurrentUser: true)
    private static let lobby = User(id: "lobby", name: Agent.name, avatarURL: nil, isCurrentUser: false)
    private static let system = User(id: "system", name: "Call", avatarURL: nil, type: .system)
    static let itemKey = "labItem"
    static let chainKey = "labChain"

    /// A run of tool calls drawn as Pixie's chain (one exyte message for the whole run).
    struct Chain { let tools: [ChatItem.Tool]; let finished: Bool }

    private var rows: [ChatToolGrouping.Row] {
        ChatToolGrouping.rows(player.items, live: player.call.status != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // F4: exyte has no chat-level header outside the scrolling list (mainHeaderBuilder
            // scrolls away with the messages), so call phase and mute sit above the ChatView.
            ChatCallHeader(call: player.call)
            ChatView<AnyView, EmptyView, DefaultMessageMenuAction>(
                messages: Self.messages(from: rows),
                didSendMessage: { _ in }
            ) { params in
                Self.row(params)
            } inputViewBuilder: { _ in
                // F1: an empty custom input view replaces exyte's composer entirely.
                EmptyView()
            }
            // B6: the live status line sits between the list and the (empty) input view.
            .betweenListAndInputViewBuilder {
                Group {
                    // Hidden while a tool chain runs: the chain says the same (as in Pixie).
                    if let status = player.call.status, !ChatToolGrouping.endsWithRunningChain(rows) {
                        ChatStatusLine(text: status)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
            }
            .showScrollToBottomButton(true)
            .showDateHeaders(true)
            .showMessageMenuOnLongPress(false)
            .setAvailableInputs([])
            // exyte's inverted UITableView draws past its top edge under the header otherwise.
            .scrollTo(scrollTo)
            .onContentOffsetChange { ScrollLog.shared.record($0) }
            .clipped()
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-lab-scroll-top"), index + 1 < args.count, let seconds = Double(args[index + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { scrollTo = ScrollToParams(.oldestMessage) }
            }
        }
    }

    // MARK: - Mapping

    static func messages(from rows: [ChatToolGrouping.Row]) -> [Message] {
        rows.map { row in
            let item: ChatItem
            switch row {
            case let .item(rowItem): item = rowItem
            case let .chain(id, tools, finished, time):
                var message = Message(id: id, user: system, createdAt: time, text: "",
                                      customData: [chainKey: Chain(tools: tools, finished: finished)])
                var hasher = Hasher()
                hasher.combine(String(describing: tools))
                hasher.combine(finished)
                message.triggerRedraw = token(hasher.finalize())
                return message
            }
            let user: User
            var text = ""
            switch item.kind {
            case let .message(speaker, body, state):
                user = speaker == .user ? you : lobby
                text = body.isEmpty && state == .streaming ? "…" : body
            default:
                user = system
            }
            var message = Message(id: item.id, user: user, status: user.isCurrentUser ? .sent : nil,
                                  createdAt: item.time, text: text,
                                  customData: [itemKey: item])
            // exyte reloads a row only when `Message ==` changes. Text is compared, but a
            // tool's state, a cut-off flag or a timing footer are not, so fold the whole
            // item into `triggerRedraw`.
            message.triggerRedraw = redrawToken(item)
            return message
        }
    }

    private static func redrawToken(_ item: ChatItem) -> UUID {
        var hasher = Hasher()
        hasher.combine(String(describing: item.kind))
        hasher.combine(item.timing)
        return token(hasher.finalize())
    }

    private static func token(_ hash: Int) -> UUID {
        let value = UInt64(bitPattern: Int64(hash))
        let hex = String(format: "%016llX", value)
        let tail = hex.dropFirst(4)
        return UUID(uuidString: "00000000-0000-0000-\(hex.prefix(4))-\(tail)") ?? UUID()
    }

    // MARK: - Rows

    @MainActor
    static func row(_ params: MessageBuilderParameters) -> AnyView {
        if let chain = params.message.customData[chainKey] as? Chain {
            return AnyView(
                ChatToolChain(tools: chain.tools, finished: chain.finished)
                    .padding(.horizontal, 16).padding(.vertical, 4)
            )
        }
        guard let item = params.message.customData[itemKey] as? ChatItem else {
            return AnyView(params.defaultMessageView())
        }
        switch item.kind {
        case let .message(speaker, text, state) where speaker == .lobby:
            return AnyView(LobbyBubble(item: item, text: text, state: state, params: params))
        case .message:
            // Your messages use exyte's own bubble, time and status.
            return AnyView(params.defaultMessageView())
        default:
            return AnyView(
                ChatNonMessageRow(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            )
        }
    }
}

/// Pixie's message: MarkdownView inside a bubble styled with exyte's theme colours. exyte's
/// `messageBuilder` replaces the whole row, so the avatar, name and time view are ours to
/// redo; only the name (from the group position exyte passes) is shown here.
private struct LobbyBubble: View {
    let item: ChatItem
    let text: String
    let state: ChatItem.TextState
    let params: MessageBuilderParameters
    @Environment(\.chatTheme) private var theme

    private var isTopOfGroup: Bool {
        params.positionInGroup == .first || params.positionInGroup == .single
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isTopOfGroup {
                Text(params.message.user.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            Group {
                if text.isEmpty {
                    Text("…").foregroundStyle(theme.colors.messageFriendText)
                } else {
                    SizedMarkdown(text: text)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.colors.messageFriendBG, in: RoundedRectangle(cornerRadius: 20))
            ChatMessageFooter(item: item).padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12).padding(.trailing, 40)
        .padding(.top, isTopOfGroup ? 8 : 2)
    }
}

/// "-lab-log-scroll" writes every exyte content offset to Documents/scroll.log with a
/// timestamp, so a bounce loop can be seen after the fact (UI tests, or a phone run).
final class ScrollLog {
    static let shared = ScrollLog()
    private let enabled = ProcessInfo.processInfo.arguments.contains("-lab-log-scroll")
    private let start = Date()
    private var lines: [String] = []
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("scroll.log")

    init() {
        guard enabled else { return }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.flush() }
    }

    func record(_ offset: CGFloat) {
        guard enabled else { return }
        lines.append(String(format: "%.3f %.1f", Date().timeIntervalSince(start), offset))
        if lines.count % 20 == 0 { flush() }
    }

    func flush() {
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
