import SwiftUI

/// Saved calls, newest first. Swipe to delete one; the toolbar deletes everything older than
/// 30 days.
struct ChatLogsView: View {
    @ObservedObject var store: ChatLogStore = .shared
    @State private var confirmBulkDelete = false

    var body: some View {
        List {
            if store.logs.isEmpty {
                ContentUnavailableView("No chat logs yet", systemImage: "text.bubble",
                                       description: Text("Each conversation with Lobby is saved here, on this iPhone."))
            }
            ForEach(store.logs) { log in
                NavigationLink { ChatLogDetailView(log: log) } label: { ChatLogRow(log: log) }
            }
            .onDelete { offsets in
                store.delete(ids: Set(offsets.map { store.logs[$0].id }))
            }
        }
        .navigationTitle("Chat logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Delete logs older than \(ChatLogStore.keepDays) days", systemImage: "calendar.badge.minus",
                           role: .destructive) { confirmBulkDelete = true }
                        .disabled(store.older().isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("chat-logs-menu")
            }
        }
        .confirmationDialog(bulkDeleteTitle, isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button("Delete \(store.older().count) logs", role: .destructive) { store.deleteOlder() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var bulkDeleteTitle: String {
        let count = store.older().count
        return "Delete \(count) \(count == 1 ? "log" : "logs") older than \(ChatLogStore.keepDays) days?"
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
    }
}
