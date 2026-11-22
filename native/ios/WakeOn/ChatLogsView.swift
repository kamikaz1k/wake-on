import SwiftUI

/// Saved calls, newest first. Standard iOS list deletion: swipe a row (or long-press it) to
/// delete it, or tap Edit to select several. While editing, the bottom bar also deletes
/// everything older than 30 days.
struct ChatLogsView: View {
    @ObservedObject var store: ChatLogStore = .shared
    @State private var selection: Set<UUID> = []
    /// "-chat-logs-editing" starts in edit mode, for screenshots.
    @State private var editMode: EditMode =
        ProcessInfo.processInfo.arguments.contains("-chat-logs-editing") ? .active : .inactive
    @State private var pendingDelete: BulkDelete?
    /// "-chat-log-newest" opens the newest log, for screenshots.
    @State private var openNewest = ProcessInfo.processInfo.arguments.contains("-chat-log-newest")

    enum BulkDelete: Identifiable {
        case selected, older
        var id: Self { self }
    }

    var body: some View {
        List(selection: $selection) {
            if store.logs.isEmpty {
                ContentUnavailableView("No chat logs yet", systemImage: "text.bubble",
                                       description: Text("Each conversation with Lobby is saved here, on this iPhone."))
            }
            ForEach(store.logs) { log in
                NavigationLink { ChatLogDetailView(log: log) } label: {
                    ChatLogRow(log: log, tokens: ChatTokens.estimate(store.thread(endingWith: log).flatMap(\.lines)))
                }
                    // Edit mode is for multi-select; swipe handles single deletes.
                    .deleteDisabled(editMode.isEditing)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.delete(ids: [log.id])
                        }
                    }
            }
            .onDelete { offsets in
                store.delete(ids: Set(offsets.map { store.logs[$0].id }))
            }
        }
        .navigationTitle("Chat history")
        // The tab bar shows on the main pages only, never over a page's own controls.
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $openNewest) {
            if let newest = store.logs.first { ChatLogDetailView(log: newest) }
        }
        .toolbar {
            if !store.logs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    EditButton().accessibilityIdentifier("chat-logs-edit")
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Delete Older Than \(ChatLogStore.keepDays) Days", role: .destructive) {
                        pendingDelete = .older
                    }
                    .disabled(store.older().isEmpty)
                    .accessibilityIdentifier("chat-logs-delete-older")
                    Spacer()
                    Button("Delete", role: .destructive) { pendingDelete = .selected }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("chat-logs-delete-selected")
                }
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                               set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { kind in
            Button(deleteLabel(kind), role: .destructive) { bulkDelete(kind, keepMemories: false) }
            if memories(kind) > 0 {
                Button("Delete but Keep Memories") { bulkDelete(kind, keepMemories: true) }
            }
        } message: { kind in
            Text(MemoryDeleteWords.message(memories(kind)))
        }
        .onChange(of: store.logs) { _, logs in
            selection.formIntersection(logs.map(\.id))
            if logs.isEmpty { editMode = .inactive }
        }
        .environment(\.editMode, $editMode)
    }

    private var dialogTitle: String {
        switch pendingDelete {
        case .older: "Delete chat logs older than \(ChatLogStore.keepDays) days?"
        default: "Delete selected chat logs?"
        }
    }

    private func ids(_ kind: BulkDelete) -> Set<UUID> {
        kind == .selected ? selection : Set(store.older().map(\.id))
    }

    private func memories(_ kind: BulkDelete) -> Int {
        MemoryStore.shared.noteCount(fromCalls: ids(kind))
    }

    private func bulkDelete(_ kind: BulkDelete, keepMemories: Bool) {
        switch kind {
        case .selected: store.delete(ids: selection, keepMemories: keepMemories)
        case .older: store.deleteOlder(keepMemories: keepMemories)
        }
        selection = []
        editMode = .inactive
    }

    private func deleteLabel(_ kind: BulkDelete) -> String {
        let count = kind == .selected ? selection.count : store.older().count
        return "Delete \(count) \(count == 1 ? "Log" : "Logs")"
    }
}

struct ChatLogRow: View {
    let log: ChatLog
    /// The whole thread's length (this chat and the ones it resumed).
    var tokens = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(log.title).lineLimit(2)
            HStack(spacing: 4) {
                Text("\(log.started.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(ChatTokens.label(tokens))")
                if ChatTokens.level(tokens) != .ok {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .accessibilityLabel("Long chat")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ChatLogDetailView: View {
    let log: ChatLog
    @ObservedObject var store: ChatLogStore = .shared
    @ObservedObject var voice: VoiceSessionController = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var memoryCount: Int { MemoryStore.shared.noteCount(fromCalls: [log.id]) }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                ChatLogTranscript(log: log, capture: store.captureURL(for: log.id))
            } else {
                lineList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatLengthWarning(tokens: ChatTokens.estimate(store.thread(endingWith: log).flatMap(\.lines)))
        }
        .navigationTitle(log.started.formatted(date: .abbreviated, time: .shortened))
        // The tab bar shows on the main pages only, never over a page's own controls.
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Every event of the call as JSON lines (see CallCapture), for replaying in Chat Lab.
            if let capture = store.captureURL(for: log.id) {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: capture) { Label("Share Call Data", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("chat-log-share-capture")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("chat-log-delete")
                Spacer()
                // A new call that knows everything said here (and in the chats this one resumed).
                Button { voice.resume(log) } label: {
                    Label("Resume Chat", systemImage: "phone.fill").labelStyle(.titleAndIcon)
                }
                .disabled(voice.phase != .idle || voice.keySource == "missing")
                .accessibilityIdentifier("chat-log-resume")
            }
        }
        .confirmationDialog("Delete this chat log?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Log", role: .destructive) {
                store.delete(ids: [log.id])
                dismiss()
            }
            if memoryCount > 0 {
                Button("Delete but Keep Memories") {
                    store.delete(ids: [log.id], keepMemories: true)
                    dismiss()
                }
            }
        } message: {
            Text(MemoryDeleteWords.message(memoryCount))
        }
    }

    /// iOS 17: the plain list of what was said.
    private var lineList: some View {
        List {
            Section {
                ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.speaker).font(.caption.bold())
                            .foregroundStyle(line.speaker == "You" ? Color.accentColor : .secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                }
            } footer: {
                Text("\(log.source) · \(log.length) long")
            }
        }
    }
}

/// A saved call in Lobby's chat view (ChatUI). With a capture it shows everything that
/// happened: tool rows for web searches and Spotify, check-ins, how the call ended. Calls from
/// before captures show just what was said.
@available(iOS 18.0, *)
struct ChatLogTranscript: View {
    @StateObject private var transcript: ChatTranscript

    init(log: ChatLog, capture: URL?) {
        _transcript = StateObject(wrappedValue: Self.transcript(for: log, capture: capture))
    }

    var body: some View {
        ChatTranscriptView(items: transcript.items, call: transcript.call, showsHeader: false)
    }

    static func transcript(for log: ChatLog, capture: URL?) -> ChatTranscript {
        if let capture, let call = CapturedCall.load(capture) {
            return ChatTranscript(steps: CaptureReplay(lines: call.lines, rawEvents: false).steps, startedAt: log.started)
        }
        let transcript = ChatTranscript()
        var items = [ChatItem(id: "source", kind: .marker("\(log.source) · \(log.length)", .system), time: log.started)]
        for (index, line) in log.lines.enumerated() {
            let speaker: ChatItem.Speaker = line.speaker == "You" ? .user : .lobby
            items.append(ChatItem(id: "line-\(index)", kind: .message(speaker, text: line.text, state: .done), time: log.started))
        }
        transcript.replaceAll(items)
        return transcript
    }
}

/// The delete confirmations' words when a chat has notes in Lobby's memory.
enum MemoryDeleteWords {
    static func message(_ memories: Int) -> String {
        guard memories > 0 else { return "This can't be undone." }
        let things = memories == 1 ? "1 thing" : "\(memories) things"
        return "This also removes \(things) Lobby remembered from it. This can't be undone."
    }
}
