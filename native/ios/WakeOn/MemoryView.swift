import SwiftUI

/// Settings › Memory: what Lobby has remembered, newest first. Each note opens the chat it
/// came from; swipe to delete one, or delete them all. Standard components only.
struct MemoryView: View {
    @ObservedObject var store: MemoryStore = .shared
    @ObservedObject var logs: ChatLogStore = .shared
    @State private var confirmDeleteAll = false

    private var notes: [Memory.Note] { store.memory.notes.reversed() }

    var body: some View {
        List {
            if notes.isEmpty {
                ContentUnavailableView("Nothing remembered yet", systemImage: "brain",
                                       description: Text("Ask Lobby to remember something, like “remember that Ella’s birthday is March 3”."))
            } else {
                Section {
                    ForEach(notes) { note in
                        if let log = logs.logs.first(where: { $0.id == note.call }) {
                            NavigationLink { ChatLogDetailView(log: log) } label: { MemoryRow(note: note, chatDeleted: false) }
                        } else {
                            MemoryRow(note: note, chatDeleted: note.call != nil)
                        }
                    }
                    .onDelete { offsets in store.delete(noteIDs: Set(offsets.map { notes[$0].id })) }
                } footer: {
                    Text("Lobby sees these at the start of every call, with older ones summarized. They stay on this iPhone and go to OpenAI only during calls and when summarized.")
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !notes.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete All", role: .destructive) { confirmDeleteAll = true }
                        .accessibilityIdentifier("memory-delete-all")
                }
            }
        }
        .confirmationDialog("Delete everything Lobby remembers?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete \(notes.count) \(notes.count == 1 ? "Memory" : "Memories")", role: .destructive) {
                store.deleteAll()
            }
        } message: {
            Text("Your chats stay. This can't be undone.")
        }
    }
}

struct MemoryRow: View {
    let note: Memory.Note
    let chatDeleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.text)
            Text(note.time.formatted(date: .abbreviated, time: .omitted) + (chatDeleted ? " · Chat deleted" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
