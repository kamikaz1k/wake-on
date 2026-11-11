import ChatClientKit
import LanguageModelChatUI
import SwiftUI
import UIKit

// LanguageModelChatUI 0.2.0 (Lakr233, UIKit, extracted from FlowDown).
//
// How it is driven. The library has no public API to add or edit messages: a
// `ConversationSession` only reads its `StorageProvider` at init, and after that it changes
// its message list itself while running inference. So this page uses the two public paths
// it has, each where it fits:
//
// 1. Lobby replies and tool calls go through the library's own pipeline. A fake
//    `ChatClient` (`BaseChatClient.provideStreamingChat`) yields the Lobby text deltas as the
//    replay produces them, and `.tool(ToolRequest)` chunks for tool rows; a `ToolProvider`
//    waits until the replay finishes the tool, then returns its result or an error. A turn
//    starts with `session.runInference(model:messageListView:input:)` and an empty user
//    input (empty user text renders nothing). Text goes through the library's
//    `BalancedEmitter`, loading row and auto-scroll, exactly as with a real model.
// 2. Everything else (history, your transcript streaming in, revisions, out-of-order turns,
//    markers, raw events, cards) is written to our in-memory `StorageProvider`, and the
//    session is told to reload it by calling the public `session.delete(_:)` with an id
//    that doesn't exist: that cancels nothing (we only do it between inferences), deletes
//    nothing, and calls `refreshContentsFromDatabase()`, which re-reads storage and
//    publishes the list with `scrolling: true`. `ConversationMessage` is a class we create
//    in storage, so messages made during inference keep their identity across reloads.
//
// Mapping, and what the library can't show:
// - Markers, raw events and cards become hint rows (a custom `MessageRole`, which the list
//   shows as one centred, half-transparent footnote line). No custom views (D5), no
//   expandable event bodies (E1).
// - A cut-off reply gets an "Interrupted" hint row after it (our addition, B3). Turn timing
//   (E2) is not shown: there is no message footer.
// - Tool rows are the library's `ToolHintView` ("Tool call for x running/completed./failed.").
//   No requested state, its tap handler is set to nil (no details, C2), no sources (C4).
// - The typing box can't be turned off; we push `chatInputView` below the visible area from
//   a container view controller (F1). Call state and the live status line are our SwiftUI
//   rows above and below the controller (F4, B6), not the library's.
struct LanguageModelChatUIRenderer: View {
    @ObservedObject var player: LabPlayer
    @StateObject private var driver = LMChatDriver()

    var body: some View {
        VStack(spacing: 0) {
            LabCallHeader(call: player.call)
            Group {
                if let controller = driver.controller {
                    LMChatHost(controller: controller).id(driver.generation)
                } else {
                    Color(.systemBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let status = player.call.status {
                LabStatusLine(text: status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6)
            }
        }
        .onReceive(player.$revision) { _ in driver.playerChanged(player) }
    }
}

// MARK: - Hosting

private struct LMChatHost: UIViewControllerRepresentable {
    let controller: LMChatContainer
    func makeUIViewController(context _: Context) -> LMChatContainer { controller }
    func updateUIViewController(_: LMChatContainer, context _: Context) {}
}

/// Holds the `ChatViewController` and makes it taller than the page by the input bar's
/// height, so the bar sits below the clipped edge. Its layout methods are `public`, not
/// `open`, so a subclass can't do this.
final class LMChatContainer: UIViewController {
    let chat: ChatViewController

    init(chat: ChatViewController) {
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.backgroundColor = .systemBackground
        addChild(chat)
        view.addSubview(chat.view)
        chat.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        chat.chatInputView.isHidden = true
        for _ in 0 ..< 2 {
            let target = CGRect(x: 0, y: 0, width: view.bounds.width,
                                height: view.bounds.height + chat.chatInputView.frame.height)
            guard chat.view.frame != target else { break }
            chat.view.frame = target
            chat.view.layoutIfNeeded()
        }
    }
}

// MARK: - Driver

@MainActor
final class LMChatDriver: ObservableObject {
    @Published private(set) var controller: LMChatContainer?
    @Published private(set) var generation = 0

    private weak var player: LabPlayer?
    private var storage = LMChatStorage()
    private var session: ConversationSession?
    private var model: ConversationSession.Model?
    private var firstItemID: String?
    /// Items already handed to the library, by storage reload or by inference.
    private var represented: Set<String> = []
    private var inferring = false
    private var lastSignature: Int?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pumpScheduled = false

    private static let hintRole = MessageRole(rawValue: "labHint")
    private var items: [LabItem] { player?.items ?? [] }

    func playerChanged(_ player: LabPlayer) {
        self.player = player
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.pumpScheduled = false
            self?.pump()
        }
    }

    private func pump() {
        let items = items
        if controller != nil, items.isEmpty || items.first?.id != firstItemID { reset() }
        wakeWaiters()
        guard !items.isEmpty else { return }
        if controller == nil { boot(items) }
        if !inferring { syncStorage() }
    }

    private func reset() {
        generation += 1
        controller = nil
        session = nil
        model = nil
        storage = LMChatStorage()
        represented = []
        inferring = false
        lastSignature = nil
        firstItemID = nil
        wakeWaiters()
    }

    /// Builds the session from the transcript so far, so history doesn't replay turn by turn.
    private func boot(_ items: [LabItem]) {
        firstItemID = items.first?.id
        let conversationID = "chatlab-lmcui-\(UUID().uuidString)"
        storage.conversationID = conversationID
        let (messages, _) = mapUntilTrigger(items)
        storage.list = messages
        lastSignature = signature(messages)

        let client = LMChatReplayClient(driver: self, generation: generation)
        let model = ConversationSession.Model(model: "lab-replay", client: client, capabilities: [.tool])
        let configuration = ConversationSession.Configuration(
            storage: storage,
            tools: LMChatReplayTools(driver: self, generation: generation),
            systemPrompt: ""
        )
        session = ConversationSessionManager.shared.session(for: conversationID, configuration: configuration)
        self.model = model
        let chat = ChatViewController(conversationID: conversationID, models: .init(chat: model),
                                      sessionConfiguration: configuration)
        chat.prefersNavigationBarManaged = true // hides the library's own title bar
        let container = LMChatContainer(chat: chat)
        container.loadViewIfNeeded()
        controller = container
    }

    /// Between inferences: write everything up to the next Lobby reply or tool into storage
    /// and reload, then start an inference for that reply or tool.
    private func syncStorage() {
        guard let session else { return }
        let (messages, trigger) = mapUntilTrigger(items)
        let signature = signature(messages)
        if signature != lastSignature {
            storage.list = messages
            lastSignature = signature
            session.delete("chatlab-refresh") // public; re-reads storage and publishes
        }
        if trigger != nil { startInference() }
    }

    private func startInference() {
        guard let session, let model, let listView = controller?.chat.messageListView else { return }
        inferring = true
        lastSignature = nil // the session's list now differs from storage
        let generation = generation
        session.runInference(model: model, messageListView: listView, input: .init(text: "")) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.inferring = false
                self.pump()
            }
        }
    }

    // MARK: Mapping LabItems to ConversationMessages

    private func isTrigger(_ item: LabItem) -> Bool {
        switch item.kind {
        case let .message(.lobby, _, state): state == .streaming
        case let .tool(tool): tool.state == .requested || tool.state == .running
        default: false
        }
    }

    private func mapUntilTrigger(_ items: [LabItem]) -> ([ConversationMessage], LabItem?) {
        var list: [ConversationMessage] = []
        for item in items {
            if !represented.contains(item.id), isTrigger(item) { return (list, item) }
            represented.insert(item.id)
            switch item.kind {
            case let .message(speaker, text, state):
                list.append(message(item.id, speaker == .user ? .user : .assistant) { $0.textContent = text })
                if state == .cutOff {
                    list.append(message(item.id + "#cut", Self.hintRole) { $0.textContent = "Interrupted" })
                }
            case let .tool(tool):
                list.append(message(item.id, .assistant) { $0.parts = Self.toolParts(item.id, tool) })
            case let .marker(text, _):
                list.append(message(item.id, Self.hintRole) { $0.textContent = text })
            case let .event(event):
                list.append(message(item.id, Self.hintRole) { $0.textContent = "\(event.direction.rawValue) \(event.type)" })
            case let .card(card):
                let text: String = switch card {
                case let .chart(title, _): "Chart: \(title)"
                case let .image(_, caption): "Image: \(caption)"
                case let .buttons(labels): labels.joined(separator: " · ")
                }
                list.append(message(item.id, Self.hintRole) { $0.textContent = text })
            }
        }
        return (list, nil)
    }

    /// Reuses the message object for an item, so rows keep their identity across reloads.
    private func message(_ key: String, _ role: MessageRole, _ fill: (ConversationMessage) -> Void) -> ConversationMessage {
        let message = storage.objects[key] ?? ConversationMessage(conversationID: storage.conversationID, role: role)
        storage.objects[key] = message
        message.role = role
        fill(message)
        return message
    }

    private static func toolParts(_ id: String, _ tool: LabItem.Tool) -> [ContentPart] {
        let state: ToolCallState = switch tool.state {
        case .requested, .running: .running
        case .done: .succeeded
        case .failed: .failed
        }
        var parts: [ContentPart] = [.toolCall(ToolCallContentPart(id: id, toolName: tool.name, apiName: tool.name,
                                                                  parameters: tool.arguments, state: state))]
        if let result = tool.result { parts.append(.toolResult(.init(toolCallID: id, result: result))) }
        return parts
    }

    private func signature(_ messages: [ConversationMessage]) -> Int {
        var hasher = Hasher()
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.textContent)
            for case let .toolCall(call) in message.parts { hasher.combine(call.state) }
        }
        return hasher.finalize()
    }

    // MARK: Waiting on the replay

    private func changed() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wakeWaiters() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    // MARK: Fake model and tools

    /// One inference step: streams the next Lobby reply, then ends with a tool call if a tool
    /// follows. Ends without one when anything else comes next, which ends the inference.
    func runStep(generation: Int, into continuation: AsyncThrowingStream<ChatResponseChunk, Swift.Error>.Continuation) async {
        defer { continuation.finish() }
        var streamedText = false
        while generation == self.generation {
            guard let next = items.first(where: { !represented.contains($0.id) }) else {
                await changed()
                continue
            }
            switch next.kind {
            case .message(.lobby, _, _) where !streamedText:
                represented.insert(next.id)
                if let message = storage.lastAssistant { storage.objects[next.id] = message }
                var sent = ""
                while generation == self.generation,
                      let current = items.first(where: { $0.id == next.id }),
                      case let .message(_, text, state) = current.kind {
                    if text.count > sent.count, text.hasPrefix(sent) {
                        continuation.yield(.text(String(text.dropFirst(sent.count))))
                        sent = text
                    }
                    if state != .streaming { break }
                    await changed()
                }
                streamedText = true
            case let .tool(tool):
                represented.insert(next.id)
                let json = try? JSONSerialization.data(withJSONObject: ["id": next.id, "name": tool.name, "arguments": tool.arguments])
                if let json, let request = try? JSONDecoder().decode(ToolRequest.self, from: json) {
                    continuation.yield(.tool(request)) // ToolRequest's init is internal; it is Codable
                }
                return
            default:
                return
            }
        }
    }

    func willCreateToolHint(_ id: String) { storage.pendingToolID = id }

    func waitForTool(_ id: String, generation: Int) async -> ToolResult {
        while generation == self.generation {
            guard let item = items.first(where: { $0.id == id }), case let .tool(tool) = item.kind else { break }
            let sources = tool.sources.map { "\($0.title): \($0.url)" }
            let output = ([tool.result ?? ""] + sources).joined(separator: "\n")
            if tool.state == .done { return ToolResult(text: output) }
            if tool.state == .failed { return ToolResult(error: output) }
            await changed()
        }
        return ToolResult(error: "Replay restarted")
    }
}

// MARK: - Library protocol conformances

/// In-memory storage. The session asks it for messages at init and on every reload, and asks
/// it to create the messages it adds during inference, so we keep references to those too.
final class LMChatStorage: StorageProvider, @unchecked Sendable {
    var conversationID = ""
    var list: [ConversationMessage] = []
    var objects: [String: ConversationMessage] = [:]
    var lastAssistant: ConversationMessage?
    var pendingToolID: String?

    func createMessage(in conversationID: String, role: MessageRole) -> ConversationMessage {
        let message = ConversationMessage(conversationID: conversationID, role: role)
        if let id = pendingToolID {
            objects[id] = message
            pendingToolID = nil
        } else if role == .assistant {
            lastAssistant = message
        }
        return message
    }

    func save(_: [ConversationMessage]) {}
    func messages(in _: String) -> [ConversationMessage] { list }
    func delete(_: [String]) {}
    func title(for _: String) -> String? { nil }
    func setTitle(_: String, for _: String) {}
}

final class LMChatReplayClient: BaseChatClient, @unchecked Sendable {
    private weak var driver: LMChatDriver?
    private let generation: Int

    init(driver: LMChatDriver, generation: Int) {
        self.driver = driver
        self.generation = generation
        super.init()
    }

    override func provideStreamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let generation = generation
        let stream = AsyncThrowingStream<ChatResponseChunk, Swift.Error> { continuation in
            Task { @MainActor [weak driver] in
                guard let driver else { continuation.finish(); return }
                await driver.runStep(generation: generation, into: continuation)
            }
        }
        return AnyAsyncSequence(stream)
    }
}

private struct LMChatReplayTool: ToolExecutor {
    let id: String
    let displayName: String
    var iconName: String { "wrench.and.screwdriver" }
}

final class LMChatReplayTools: ToolProvider, @unchecked Sendable {
    private weak var driver: LMChatDriver?
    private let generation: Int

    init(driver: LMChatDriver, generation: Int) {
        self.driver = driver
        self.generation = generation
    }

    func enabledTools() async -> [ChatRequestBody.Tool] { [] }
    func prepareForConversation() async {}

    func findTool(for request: ToolRequest) async -> ToolExecutor? {
        await driver?.willCreateToolHint(request.id)
        return LMChatReplayTool(id: request.id, displayName: request.name)
    }

    func executeTool(_ tool: ToolExecutor, parameters _: String, anchor _: UIView?) async throws -> ToolResult {
        guard let tool = tool as? LMChatReplayTool, let driver else { return ToolResult(error: "Unknown tool") }
        return await driver.waitForTool(tool.id, generation: generation)
    }
}
