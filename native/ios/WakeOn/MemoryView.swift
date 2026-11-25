import SwiftUI

/// Settings › Memory: what Pixie has remembered, newest first. Each note opens the chat it
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
                                       description: Text("What \(Agent.name) learns in your calls will show up here."))
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
                    Text("\(Agent.name) sees these at the start of every call, with older ones summarized. They stay on this iPhone and go to OpenAI only during calls and when summarized.")
                }
            }
            #if DEBUG
            MemoryDebugSection(store: store)
            #endif
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
        .confirmationDialog("Delete everything \(Agent.name) remembers?", isPresented: $confirmDeleteAll,
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

#if DEBUG
/// Debug builds: write the summaries now, and see what a call starts with.
struct MemoryDebugSection: View {
    @ObservedObject var store: MemoryStore
    @State private var running = false
    @State private var result: String?

    private var memory: Memory { store.memory }

    var body: some View {
        Section {
            LabeledContent("Notes", value: "\(memory.notes.count)")
            LabeledContent("Summaries", value: "\(memory.summaries.count)")
            LabeledContent("Lines at call start", value: "\(memory.cover().count) of \(memory.roots.count)")
            LabeledContent("Ready to summarize", value: "\(memory.ready.count)")
            Button {
                running = true
                Task {
                    let written = await MemoryJob.run()
                    result = written == 0 && memory.ready.isEmpty
                        ? "Nothing ready: a summary needs \(Memory.block) notes in a row."
                        : "Wrote \(written) \(written == 1 ? "summary" : "summaries")."
                    running = false
                }
            } label: {
                if running { ProgressView() } else { Text("Write Summaries Now") }
            }
            .disabled(running)
            .accessibilityIdentifier("memory-summarize")
            NavigationLink("Start-of-Call Memory") {
                ScrollView {
                    Text(memory.callText() ?? "Empty.")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Start of Call")
                .navigationBarTitleDisplayMode(.inline)
            }
        } header: {
            Text("Debug")
        } footer: {
            if let result { Text(result) }
        }
    }
}
#endif
