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
                NavigationLink { ChatLogDetailView(log: log) } label: { ChatLogRow(log: log) }
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
        .navigationTitle("Chat logs")
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
            Button(deleteLabel(kind), role: .destructive) {
                switch kind {
                case .selected: store.delete(ids: selection)
                case .older: store.deleteOlder()
                }
                selection = []
                editMode = .inactive
            }
        } message: { _ in
            Text("This can't be undone.")
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

    private func deleteLabel(_ kind: BulkDelete) -> String {
        let count = kind == .selected ? selection.count : store.older().count
        return "Delete \(count) \(count == 1 ? "Log" : "Logs")"
    }
}

struct ChatLogRow: View {
    let log: ChatLog
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(log.title).lineLimit(2)
            Text("\(log.started.formatted(date: .abbreviated, time: .shortened)) · \(log.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ChatLogDetailView: View {
    let log: ChatLog
    @ObservedObject var store: ChatLogStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
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
                let seconds = Int(log.ended.timeIntervalSince(log.started).rounded())
                Text("\(log.source) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) long")
            }
        }
        .navigationTitle(log.started.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("chat-log-delete")
            }
        }
        .confirmationDialog("Delete this chat log?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Log", role: .destructive) {
                store.delete(ids: [log.id])
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}
