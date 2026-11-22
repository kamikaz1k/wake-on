import Foundation
import UIKit

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
    /// The earlier call this one picked up from (a resumed chat), if any.
    var resumes: UUID?
    /// The largest lookup request in the call, in tokens as OpenAI counted them (instructions,
    /// tools and transcript). Nil when nothing was looked up, or for older logs.
    var lookupTokens: Int?

    /// The first thing the user said, for the list.
    var title: String {
        let first = lines.first { $0.speaker == "You" }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "Lobby only"
    }

    /// "1:12"
    var length: String {
        let seconds = Int(ended.timeIntervalSince(started).rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    var source: String {
        switch trigger {
        case "wake_word": "Hey Lobby"
        case "app_intent_fast", "app_intent": "Action Button"
        case "in_app": "In app"
        case "resume": "Resumed"
        case "browser": "Browser"
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
    /// False while the saved file exists but can't be read yet (iOS keeps protected files
    /// unreadable after a restart until the first unlock). Nothing is written then: writing
    /// would replace every older log with just the new ones, which once lost all of them.
    private var loaded = false
    private var protectedDataObserver: NSObjectProtocol?
    /// Each log's full call data (`CallCapture`), named by the log's id.
    let capturesFolder: URL

    init(url: URL = ChatLogStore.defaultURL, capturesFolder: URL = CallCapture.defaultFolder) {
        self.url = url
        self.capturesFolder = capturesFolder
        loaded = load()
        if !loaded {
            protectedDataObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryLoad() }
            }
        }
    }

    /// Reads the saved logs, keeping any added since launch. False if the file is there but
    /// can't be read yet; a damaged file is kept aside and a new one started.
    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let saved = try? JSONDecoder().decode([ChatLog].self, from: data) else {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return true
        }
        let added = Set(logs.map(\.id))
        logs = (logs + saved.filter { !added.contains($0.id) }).sorted { $0.started > $1.started }
        return true
    }

    /// Once the file can be read: merge it with what was added meanwhile, and save both.
    private func retryLoad() {
        guard !loaded, load() else { return }
        loaded = true
        if let protectedDataObserver { NotificationCenter.default.removeObserver(protectedDataObserver) }
        protectedDataObserver = nil
        save()
    }

    nonisolated static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("chat-logs.json")
    }

    /// Saves the log and, if given, its call capture under the same id. Returns false for a
    /// call with nothing said, which isn't kept.
    @discardableResult
    func add(_ log: ChatLog, capture: CallCapture? = nil) -> Bool {
        guard !log.lines.isEmpty else { return false }
        logs.insert(log, at: 0)
        save()
        capture?.save(in: capturesFolder)
        return true
    }

    func delete(ids: Set<UUID>) {
        logs.removeAll { ids.contains($0.id) }
        save()
        for id in ids { try? FileManager.default.removeItem(at: CallCapture.url(for: id, in: capturesFolder)) }
    }

    /// The whole thread a log belongs to, oldest first: the calls it resumed, then itself.
    /// Deleted parts are skipped.
    func thread(endingWith log: ChatLog) -> [ChatLog] {
        Self.thread(endingWith: log, in: logs)
    }

    nonisolated static func thread(endingWith log: ChatLog, in logs: [ChatLog]) -> [ChatLog] {
        var chain = [log]
        var seen: Set<UUID> = [log.id]
        while let previous = chain.first?.resumes, !seen.contains(previous),
              let earlier = logs.first(where: { $0.id == previous }) {
            chain.insert(earlier, at: 0)
            seen.insert(previous)
        }
        return chain
    }

    /// The log's call capture file, if it has one (calls from before captures don't).
    func captureURL(for id: UUID) -> URL? {
        let url = CallCapture.url(for: id, in: capturesFolder)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        if !loaded {
            loaded = load()
            guard loaded else { return }  // kept in memory until the file can be read
        }
        guard let data = try? JSONEncoder().encode(logs) else { return }
        // Readable after the first unlock, so calls from the lock screen (Action Button,
        // Hey Lobby) can read and add to it.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
