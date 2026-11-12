import Foundation

/// Everything that happened in one call, as JSON lines, so real conversations can be replayed
/// in Chat Lab: every event from the Live API (as received), every event the app sent, the
/// session config (instructions and tools), and what the app did itself (tool results, opening
/// Spotify, media commands, why the call ended).
///
/// Saved as `<chat log id>.jsonl` in Application Support/call-captures next to the chat log, and
/// deleted with it. Each line: `{"t_ms": ms since the trigger, "source": "server" | "client" |
/// "app", "event": {…}}`. App events have types starting with `app.`.
@MainActor
final class CallCapture {
    enum Source: String { case server, client, app }

    let id: UUID
    private let origin: UInt64
    private var lines: [Data] = []
    private var bytes = 0
    private var truncated = false
    /// Set once saved: later events (Spotify opening after the call) are appended to it.
    private var savedURL: URL?
    /// A long call's transcript deltas add up; stop before a capture gets unwieldy.
    static let byteLimit = 8_000_000

    init(id: UUID = UUID(), origin: UInt64) {
        self.id = id
        self.origin = origin
    }

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("call-captures", isDirectory: true)
    }

    nonisolated static func url(for id: UUID, in folder: URL = defaultFolder) -> URL {
        folder.appendingPathComponent("\(id.uuidString).jsonl")
    }

    func record(_ source: Source, _ event: [String: Any], at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard !truncated else { return }
        let ms = (Double(Int64(bitPattern: time &- origin)) / 1e4).rounded() / 100
        let line: [String: Any] = ["t_ms": ms, "source": source.rawValue, "event": Self.jsonSafe(event)]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        if bytes + data.count > Self.byteLimit {
            truncated = true
            let note: [String: Any] = ["t_ms": ms, "source": "app", "event": ["type": "app.capture_truncated", "bytes": bytes]]
            if var stop = try? JSONSerialization.data(withJSONObject: note) { stop.append(0x0A); write(stop) }
            return
        }
        bytes += data.count
        write(data)
    }

    /// An app event: `type` gets the `app.` prefix.
    func app(_ type: String, _ fields: [String: Any] = [:], at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        var event = fields
        event["type"] = "app.\(type)"
        record(.app, event, at: time)
    }

    /// Writes everything so far; anything recorded afterwards is appended straight to the file.
    func save(in folder: URL = defaultFolder) {
        let url = Self.url(for: id, in: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? lines.reduce(into: Data()) { $0.append($1) }.write(to: url, options: [.atomic, .completeFileProtection])
        lines = []
        savedURL = url
    }

    private func write(_ data: Data) {
        guard let savedURL else { return lines.append(data) }
        guard let handle = try? FileHandle(forWritingTo: savedURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// A saved capture's lines, decoded.
    nonisolated static func read(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// Milestone fields can hold values JSON can't (Durations, enums): keep those as text.
    private static func jsonSafe(_ value: [String: Any]) -> [String: Any] {
        if JSONSerialization.isValidJSONObject(value) { return value }
        return value.mapValues { item in
            if let nested = item as? [String: Any] { return jsonSafe(nested) }
            return JSONSerialization.isValidJSONObject([item]) ? item : String(describing: item)
        }
    }
}
