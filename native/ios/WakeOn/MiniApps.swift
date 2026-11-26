import AppIntents
import CryptoKit
import SwiftUI
import UIKit
import WebKit

/// A page Pixie made (show_visual) that the user saved: it opens full screen from My Apps, by
/// asking Pixie, from Shortcuts (and so the Home Screen, the Action Button or Control Center),
/// or from `wakeon://app/<id>`. A live one (`refresh` set) is remade with fresh data when it's
/// opened after a while.
struct MiniApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String
    var html: String
    /// The request that remakes it with fresh data; empty when it works on its own.
    var refresh: String
    var created = Date()
    var updated = Date()
    /// The page before the last change, for Undo.
    var previousHTML: String?
    /// SHA-256 of the page as first shown, so its chat row knows it's saved.
    var origin: String

    var shortID: String { String(id.uuidString.lowercased().prefix(6)) }
    var isLive: Bool { !refresh.isEmpty }
}

enum MiniApps {
    static let toolName = "mini_apps"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "The user's saved apps: pages from show_visual they kept on their phone. List them, open one on screen, save the page you last showed, read one's HTML, or change one.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["list", "open", "save", "get", "update"]],
                "app": ["type": "string", "description": "For open, get and update: the app's id from list, or its name. Empty otherwise."],
                "name": ["type": "string", "description": "For save: a short name, or empty to use the page's title."],
                "html": ["type": "string", "description": "For update: the complete new HTML document. Empty otherwise."],
            ],
            "required": ["action", "app", "name", "html"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    The user can keep pages you show as apps on their phone. When they ask to save, keep or \
    bookmark what's on screen, call mini_apps with action save. When they ask to open one of their \
    apps, call it with action open (list first if you don't know the name). To change an app \
    ("make the tip calculator round up"), get its HTML, then update it with the whole new \
    document, keeping what they didn't ask to change.
    """

    static func origin(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The symbol if iOS has it, else a generic app icon.
    static func icon(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && UIImage(systemName: name) != nil ? name : "app"
    }

    static func listText(_ apps: [MiniApp]) -> String {
        guard !apps.isEmpty else { return "No saved apps yet." }
        return apps.map { app in
            "\(app.shortID): \(app.name)" + (app.isLive ? " (live: \(app.refresh))" : " (works on its own)")
        }.joined(separator: "\n")
    }

    /// Runs one tool call. `lastVisual` is the page shown last in this call.
    @MainActor
    static func perform(_ arguments: [String: Any], lastVisual: ChatItem.Visual?,
                        store: MiniAppStore = .shared) -> String {
        let action = arguments["action"] as? String ?? ""
        let key = (arguments["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch action {
        case "list":
            return listText(store.apps)
        case "save":
            guard let lastVisual, lastVisual.complete else {
                return "Nothing to save: show the page first with show_visual."
            }
            var visual = lastVisual
            let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { visual.title = name }
            let app = store.add(visual)
            return "Saved as \"\(app.name)\" (\(app.shortID)). They can open it from My Apps on the main screen, ask you to open it, or add it to the Home Screen with the Shortcuts app (Open Mini App)."
        case "open", "get", "update":
            guard let app = store.find(key) else {
                return "No saved app matches \"\(key)\". Saved apps:\n" + listText(store.apps)
            }
            if action == "open" {
                store.open(app)
                return "Opened \"\(app.name)\" on their screen."
            }
            if action == "get" { return app.html }
            let html = arguments["html"] as? String ?? ""
            guard html.contains("<") else { return "Not updated: send the whole new HTML document." }
            store.update(app.id, html: html)
            return "Updated \"\(app.name)\". They can undo it from the app's menu."
        default:
            return "Unknown action \(action)."
        }
    }
}

/// The saved apps, kept in `Documents/mini-apps.json`.
@MainActor
final class MiniAppStore: ObservableObject, VisualSaver {
    static let shared = MiniAppStore()

    @Published private(set) var apps: [MiniApp] = []
    /// The app shown full screen (over everything, see ContentView).
    @Published var opened: MiniApp?
    private let file: URL

    init(file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mini-apps.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([MiniApp].self, from: data) {
            apps = saved
        }
    }

    func isSaved(_ visual: ChatItem.Visual) -> Bool {
        let origin = MiniApps.origin(visual.html)
        return apps.contains { $0.origin == origin }
    }

    func save(_ visual: ChatItem.Visual) -> Bool {
        if !isSaved(visual) { add(visual) }
        return true
    }

    @discardableResult
    func add(_ visual: ChatItem.Visual) -> MiniApp {
        let origin = MiniApps.origin(visual.html)
        if let existing = apps.first(where: { $0.origin == origin }) { return existing }
        let title = visual.title.trimmingCharacters(in: .whitespaces)
        let app = MiniApp(name: title.isEmpty ? "Saved page" : title, icon: MiniApps.icon(visual.icon),
                          html: visual.html, refresh: visual.refresh.trimmingCharacters(in: .whitespaces),
                          origin: origin)
        apps.insert(app, at: 0)
        persist()
        VoiceSessionController.appLog("mini_app_saved id=\(app.shortID) live=\(app.isLive) bytes=\(app.html.utf8.count)")
        return app
    }

    /// By id (or its first characters) or by name.
    func find(_ key: String) -> MiniApp? {
        let key = key.lowercased()
        guard !key.isEmpty else { return nil }
        return apps.first { $0.id.uuidString.lowercased().hasPrefix(key) }
            ?? apps.first { $0.name.lowercased() == key }
            ?? apps.first { $0.name.lowercased().contains(key) || key.contains($0.name.lowercased()) }
    }

    func app(_ id: UUID) -> MiniApp? { apps.first { $0.id == id } }

    func open(_ app: MiniApp) { opened = app }

    /// A new page (Pixie's change or a refresh). `undoable` keeps the old one for Undo.
    func update(_ id: UUID, html: String, undoable: Bool = true) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        if undoable { apps[index].previousHTML = apps[index].html }
        apps[index].html = html
        apps[index].updated = Date()
        changed(index)
    }

    func undo(_ id: UUID) {
        guard let index = apps.firstIndex(where: { $0.id == id }), let previous = apps[index].previousHTML else { return }
        apps[index].previousHTML = nil
        apps[index].html = previous
        apps[index].updated = Date()
        changed(index)
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].name = name
        changed(index)
    }

    /// Deletes the app and the data it kept (its own website data store).
    func delete(_ id: UUID) {
        apps.removeAll { $0.id == id }
        if opened?.id == id { opened = nil }
        persist()
        WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
    }

    private func changed(_ index: Int) {
        if opened?.id == apps[index].id { opened = apps[index] }
        persist()
    }

    private func persist() {
        do { try JSONEncoder().encode(apps).write(to: file, options: .atomic) }
        catch { VoiceSessionController.appLog("mini_apps_save_failed \(error)") }
        WakeShortcuts.updateAppShortcutParameters()
    }
}

/// Remakes a live app with fresh data: with an OpenAI key straight from OpenAI, with an invite
/// code through the Pixie server (which holds the prompt).
enum MiniAppRefresher {
    /// Opened after this long, a live app refreshes by itself.
    static let staleAfter: TimeInterval = 15 * 60
    static let model = "gpt-6.1-terra"
    static let maxHTML = 30_000

    /// Kept the same as the server's REFRESH_INSTRUCTIONS.
    static let instructions = """
    You update a small app saved on the user's phone: one self-contained HTML page. You get the \
    request it answers, the current time and the page. Look up fresh data for the request on the \
    web, then reply with the complete updated HTML document only, no commentary or code fences: \
    keep the layout, style, features and any localStorage keys, and change only the data and \
    dates. If you can't find fresh data, return the page unchanged.
    """

    static func isStale(_ app: MiniApp, now: Date = Date()) -> Bool {
        app.isLive && now.timeIntervalSince(app.updated) > staleAfter
    }

    static func input(_ app: MiniApp, now: Date = Date()) -> String {
        "\(LiveVoiceConfig.clockLine(now))\nRequest: \(app.refresh)\n\nCurrent page:\n\(app.html)"
    }

    static func request(_ app: MiniApp, now: Date = Date()) -> [String: Any] {
        ["model": model, "instructions": instructions, "input": input(app, now: now), "store": false,
         "tools": [["type": "web_search"]], "max_output_tokens": 16000]
    }

    /// The page in a reply: code fences and anything around the document are dropped.
    static func page(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.range(of: "<!doctype", options: .caseInsensitive)?.lowerBound
            ?? text.range(of: "<html", options: .caseInsensitive)?.lowerBound {
            text = String(text[start...])
        }
        if let end = text.range(of: "</html>", options: [.caseInsensitive, .backwards])?.upperBound {
            text = String(text[..<end])
        }
        guard text.lowercased().contains("<html") || text.lowercased().hasPrefix("<!doctype"),
              text.utf8.count <= maxHTML else { return nil }
        return text
    }

    static func refresh(_ app: MiniApp, credential: String) async throws -> String {
        let url: URL
        let body: [String: Any]
        if LobbyServer.isInviteCode(credential) {
            guard let server = LobbyServer.url else { throw VoiceError.message("No \(Agent.name) server in this build.") }
            url = server.appendingPathComponent("v1/apps/refresh")
            body = ["request": app.refresh, "html": app.html, "now": LiveVoiceConfig.clockLine()]
        } else {
            url = MemorySummarizer.openAI
            body = request(app)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = MemorySummarizer.outputText(json), let page = page(from: text) else {
            throw VoiceError.message("refresh failed: HTTP \(status)")
        }
        return page
    }
}

/// My Apps: the saved apps, newest first. Tap to open; swipe to delete; hold to rename.
struct MiniAppsView: View {
    @ObservedObject var store: MiniAppStore = .shared
    @State private var renaming: MiniApp?
    @State private var newName = ""
    @State private var showHomeScreenHelp = false

    var body: some View {
        List {
            if store.apps.isEmpty {
                ContentUnavailableView("No Apps Yet", systemImage: "square.grid.2x2",
                                       description: Text("Ask \(Agent.name) for a calculator, a checklist or this week's weather, then tap Save as App."))
            }
            ForEach(store.apps) { app in
                Button { store.open(app) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).foregroundStyle(.primary)
                            Text(app.isLive ? "Live · updated \(app.updated.formatted(.relative(presentation: .named)))" : "Works offline")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: app.icon)
                    }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { newName = app.name; renaming = app }
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(app.id) }
                }
                .accessibilityIdentifier("mini-app-row")
            }
            .onDelete { offsets in offsets.map { store.apps[$0].id }.forEach(store.delete) }
            if !store.apps.isEmpty {
                Section {
                    Button("Add to Home Screen", systemImage: "plus.square.on.square") { showHomeScreenHelp = true }
                }
            }
        }
        .navigationTitle("My Apps")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let renaming { store.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showHomeScreenHelp) { HomeScreenHelp() }
    }
}

/// iOS doesn't let apps add Home Screen icons, so this walks through Shortcuts.
struct HomeScreenHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    OnboardingRow(icon: "1.circle", tint: .primary, textStyle: .primary, text: "Open Shortcuts and tap +")
                    OnboardingRow(icon: "2.circle", tint: .primary, textStyle: .primary, text: "Search for Pixie, then tap Open Mini App")
                    OnboardingRow(icon: "3.circle", tint: .primary, textStyle: .primary, text: "Tap App and pick one of your apps")
                    OnboardingRow(icon: "4.circle", tint: .primary, textStyle: .primary, text: "Tap the shortcut's name at the top, then Add to Home Screen")
                } footer: {
                    Text("The same shortcut works on the Action Button and in Control Center. You can also say “Open my tip calculator” to \(Agent.name).")
                }
                Section {
                    Button("Open Shortcuts", systemImage: "arrow.up.right.square") {
                        if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                    }
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// One saved app, full screen. A live app that's stale refreshes when it opens.
struct MiniAppScreen: View {
    let app: MiniApp
    @ObservedObject var store: MiniAppStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var refreshError: String?
    @State private var showHomeScreenHelp = false

    var body: some View {
        NavigationStack {
            VisualWebView(html: app.html, storage: app.id)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(app.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("mini-app-done")
                    }
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            if app.isLive {
                                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                                    .disabled(refreshing)
                            }
                            if app.previousHTML != nil {
                                Button("Undo Last Change", systemImage: "arrow.uturn.backward") { store.undo(app.id) }
                            }
                            Button("Add to Home Screen", systemImage: "plus.square.on.square") { showHomeScreenHelp = true }
                        }
                        .accessibilityIdentifier("mini-app-menu")
                        if refreshing { ProgressView() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let refreshError {
                        Text(refreshError).font(.footnote).foregroundStyle(.secondary)
                            .padding(8).frame(maxWidth: .infinity).background(.bar)
                    }
                }
        }
        .sheet(isPresented: $showHomeScreenHelp) { HomeScreenHelp() }
        .task { if MiniAppRefresher.isStale(app) { await refresh() } }
    }

    private func refresh() async {
        guard !refreshing else { return }
        guard let credential = OpenAIKeyStore.load()?.key else {
            refreshError = "Set up an invite code or key to refresh."
            return
        }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }
        let current = store.app(app.id) ?? app
        do {
            let html = try await MiniAppRefresher.refresh(current, credential: credential)
            store.update(app.id, html: html, undoable: false)
            VoiceSessionController.appLog("mini_app_refreshed id=\(app.shortID) bytes=\(html.utf8.count)")
        } catch {
            VoiceSessionController.appLog("mini_app_refresh_failed id=\(app.shortID) \(error)")
            refreshError = "Couldn't refresh. Showing the version from \(current.updated.formatted(.relative(presentation: .named)))."
        }
    }
}

// MARK: - Shortcuts

struct MiniAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mini App"
    static var defaultQuery = MiniAppQuery()

    let id: UUID
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }

    init(_ app: MiniApp) {
        id = app.id
        name = app.name
        icon = app.icon
    }
}

struct MiniAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [MiniAppEntity] {
        identifiers.compactMap { MiniAppStore.shared.app($0) }.map(MiniAppEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MiniAppEntity] {
        MiniAppStore.shared.apps.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(MiniAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MiniAppEntity] {
        MiniAppStore.shared.apps.map(MiniAppEntity.init)
    }
}

/// Opens a saved app full screen. Add it to the Home Screen from Shortcuts.
struct OpenMiniAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Mini App"
    static var description = IntentDescription("Open one of the apps you saved from Pixie.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "App")
    var app: MiniAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceSessionController.appLog("intent OpenMiniAppIntent")
        if let saved = MiniAppStore.shared.app(app.id) { MiniAppStore.shared.open(saved) }
        return .result()
    }
}
