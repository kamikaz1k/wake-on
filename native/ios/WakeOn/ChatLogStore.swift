import Foundation

/// One finished call's transcript.
struct ChatLog: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable {
        var speaker: String
        var text: String
    }
    var id = UUID()
    var started: Date
    var ended: Date
    /// How the call started: "wake_word", "app_intent_fast" (Action Button), "in_app"…
    var trigger: String
    var lines: [Line]

    /// The first thing the user said, for the list.
    var title: String {
        let first = lines.first { $0.speaker == "You" }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "Lobby only"
    }

    var source: String {
        switch trigger {
        case "wake_word": "Hey Lobby"
        case "app_intent_fast", "app_intent": "Action Button"
        case "in_app": "In app"
        default: trigger
        }
    }
}

/// Saved chat logs, newest first, in Application Support/chat-logs.json on this iPhone.
@MainActor
final class ChatLogStore: ObservableObject {
    static let shared = ChatLogStore()
    /// The bulk delete's cut-off.
    static let keepDays = 30

    @Published private(set) var logs: [ChatLog] = []
    private let url: URL

    init(url: URL = ChatLogStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ChatLog].self, from: data) {
            logs = saved.sorted { $0.started > $1.started }
        }
    }

    nonisolated static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("chat-logs.json")
    }

    func add(_ log: ChatLog) {
        guard !log.lines.isEmpty else { return }
        logs.insert(log, at: 0)
        save()
    }

    func delete(ids: Set<UUID>) {
        logs.removeAll { ids.contains($0.id) }
        save()
    }

    /// Logs that the bulk delete would remove.
    func older(than days: Int = keepDays, now: Date = Date()) -> [ChatLog] {
        Self.older(logs, than: days, now: now)
    }

    func deleteOlder(than days: Int = keepDays, now: Date = Date()) {
        delete(ids: Set(older(than: days, now: now).map(\.id)))
    }

    nonisolated static func older(_ logs: [ChatLog], than days: Int, now: Date) -> [ChatLog] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return logs.filter { $0.started < cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
