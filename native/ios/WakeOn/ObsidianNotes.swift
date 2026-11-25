import SwiftUI
import UniformTypeIdentifiers

/// Pixie's "note that down" tool: writes Markdown straight into the user's Obsidian vault.
/// The vault lives in Obsidian's iCloud folder, which other apps can't open by themselves, so
/// the user picks the vault folder once in Settings (the system folder picker) and the app
/// keeps a bookmark to it. Writing needs no Obsidian and no hang-up, so the call goes on, and
/// it works in the background too. iCloud syncs the file to Obsidian on every device.
enum ObsidianNotes {
    static let toolName = "save_note"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Save a note in the user's Obsidian notes: add to today's daily note, or to a note with a title (created if it doesn't exist, else added to the end).",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "The note's title, such as \"Shopping list\" or \"Gift ideas\". Empty for today's daily note.",
                ],
                "text": [
                    "type": "string",
                    "description": "What to add, in Markdown. Short lines or \"- \" list items; the user's words, tidied up.",
                ],
            ],
            "required": ["title", "text"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks to note, jot down, write down or add something to their notes or a list, \
    call save_note: an empty title for a quick note (today's daily note), or the note's title \
    when they name one ("add milk to my shopping list" is title "Shopping list", text "- milk"). \
    Then confirm in a few words; the call goes on.
    """

    struct Request: Equatable {
        /// Empty for today's daily note.
        var title: String
        var text: String
    }

    static func request(title: String, text: String) -> Request? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Request(title: fileName(title), text: text)
    }

    /// A title Obsidian accepts as a file name: no \ / : * ? " < > | # ^ [ ], at most 100 characters.
    static func fileName(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { banned.contains($0) ? " " : $0 }))
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    // MARK: - Where notes go, from the vault's own Obsidian settings

    /// The vault-relative path for a note: daily notes follow the Daily notes plugin
    /// (`.obsidian/daily-notes.json`: folder and date format), titled notes go where Obsidian
    /// puts new notes (`.obsidian/app.json`: "In the folder specified below").
    static func path(for request: Request, vault: URL, date: Date = Date(), calendar: Calendar = .current) -> String {
        if request.title.isEmpty {
            let daily = settings(vault, "daily-notes.json")
            let format = (daily["format"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YYYY-MM-DD"
            return join(daily["folder"] as? String, dailyName(format: format, date: date, calendar: calendar) + ".md")
        }
        let app = settings(vault, "app.json")
        let folder = app["newFileLocation"] as? String == "folder" ? app["newFileFolderPath"] as? String : nil
        return join(folder, request.title + ".md")
    }

    /// A date in Moment.js format (what Obsidian uses), e.g. "YYYY-MM-DD" or "YYYY/MM/dddd, MMMM Do".
    static func dailyName(format: String, date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var result = ""
        var rest = Substring(format)
        // Longest tokens first. "Do" (1st, 2nd) has no DateFormatter pattern.
        let tokens: [(String, String)] = [("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"),
                                          ("MM", "MM"), ("M", "M"), ("DDDD", "DDD"), ("DD", "dd"), ("Do", ""),
                                          ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("ww", "ww"), ("w", "w")]
        while let first = rest.first {
            if first == "[" {
                let literal = rest.dropFirst().prefix { $0 != "]" }
                result += literal
                rest = rest.dropFirst(literal.count + 2)
                continue
            }
            if let (token, pattern) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                if token == "Do" {
                    let day = calendar.component(.day, from: date)
                    let suffix = (11...13).contains(day % 100) ? "th"
                        : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
                    result += "\(day)\(suffix)"
                } else {
                    formatter.dateFormat = pattern
                    result += formatter.string(from: date)
                }
                rest = rest.dropFirst(token.count)
                continue
            }
            result.append(first)
            rest = rest.dropFirst()
        }
        return result
    }

    private static func settings(_ vault: URL, _ name: String) -> [String: Any] {
        let url = vault.appendingPathComponent(".obsidian").appendingPathComponent(name)
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static func join(_ folder: String?, _ file: String) -> String {
        let folder = (folder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return folder.isEmpty ? file : folder + "/" + file
    }

    // MARK: - Writing

    /// The text added to a note: on its own line, after what's there.
    static func appended(_ text: String, to existing: String) -> String {
        guard !existing.isEmpty else { return text + "\n" }
        let base = existing.hasSuffix("\n") ? existing : existing + "\n"
        return base + text + "\n"
    }

    enum Failure: Error, Equatable { case noVault, noAccess, write(String) }

    /// Adds the note; returns its vault-relative path ("2026-11-15.md").
    @discardableResult
    static func save(_ request: Request, in vault: URL, date: Date = Date()) throws -> String {
        let relative = path(for: request, vault: vault, date: date)
        let url = vault.appendingPathComponent(relative)
        var failure: Error?
        var coordinationError: NSError?
        // iCloud files are written through a coordinator, so the sync daemon sees the change.
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try appended(request.text, to: existing).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw Failure.write(error.localizedDescription) }
        return relative
    }

    /// Saves to the vault picked in Settings.
    static func save(_ request: Request) throws -> String {
        guard let vault = ObsidianVault.url else { throw Failure.noVault }
        guard vault.startAccessingSecurityScopedResource() else { throw Failure.noAccess }
        defer { vault.stopAccessingSecurityScopedResource() }
        return try save(request, in: vault)
    }
}

/// The vault folder the user picked, kept as a bookmark (the picker's permission lasts only
/// while the app keeps the bookmark).
enum ObsidianVault {
    static let key = "obsidian.vaultBookmark"
    static let changed = Notification.Name("ObsidianVaultChanged")

    static var isSet: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: key) }
        }
        return url
    }

    static var name: String? { url?.lastPathComponent }

    /// From the folder picker.
    static func choose(_ folder: URL) throws {
        guard folder.startAccessingSecurityScopedResource() else { throw ObsidianNotes.Failure.noAccess }
        defer { folder.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(try folder.bookmarkData(), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Settings row: which vault Pixie writes to; tap to pick it (iCloud Drive › Obsidian › vault).
struct ObsidianVaultRow: View {
    @State private var name = ObsidianVault.name
    @State private var picking = false
    @State private var problem: String?

    var body: some View {
        Button { picking = true } label: {
            LabeledContent("Obsidian Vault", value: name ?? "Choose…")
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("simple-obsidian-vault")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try ObsidianVault.choose(try result.get())
                name = ObsidianVault.name
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
        .swipeActions {
            if name != nil {
                Button("Remove", role: .destructive) { ObsidianVault.forget(); name = nil }
            }
        }
        .alert("Couldn't use that folder", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }
}
