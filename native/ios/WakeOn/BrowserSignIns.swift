import SwiftUI
import WebKit

/// Which sites the in-app browser keeps you signed in to. Everything else is wiped when the
/// app starts and whenever the browser closes, so other sites leave no cookies behind.
/// You type passwords yourself; Pixie never enters them.
enum BrowserSignIns {
    static let key = "browser.signInDomains"
    /// Sites kept by default. When Pixie gains a deep integration with a service (signing in to
    /// it, like Spotify), add that service's sign-in domain here: people who already edited
    /// their list get it too (once, see `addingNewDefaults`), and can still remove it.
    static let defaultDomains = ["spotify.com"]
    /// The defaults already added to a saved list, so one the user removed stays removed.
    static let seenKey = "browser.signInDefaultsSeen"

    /// A saved list plus the defaults it hasn't been offered yet.
    static func addingNewDefaults(to saved: [String], seen: [String]) -> [String] {
        saved + defaultDomains.filter { !seen.contains($0) && !saved.contains($0) }
    }

    /// Runs once per launch, before the list is first read.
    @MainActor static func adoptNewDefaults() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key) {
            let seen = defaults.string(forKey: seenKey).map(decode) ?? []
            let updated = addingNewDefaults(to: decode(saved), seen: seen)
            if updated != decode(saved) { defaults.set(encode(updated), forKey: key) }
        }
        defaults.set(encode(defaultDomains), forKey: seenKey)
    }

    static var domains: [String] {
        get {
            guard let saved = UserDefaults.standard.string(forKey: key) else { return defaultDomains }
            return decode(saved)
        }
        set { UserDefaults.standard.set(encode(newValue), forKey: key) }
    }

    static func decode(_ saved: String) -> [String] {
        saved.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func encode(_ domains: [String]) -> String { domains.joined(separator: "\n") }

    /// "https://www.Spotify.com/login" → "spotify.com". Nil for anything that isn't a host.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: ".-"))
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
              text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text
    }

    /// Whether a website data record (named by its site, e.g. "spotify.com") is kept.
    static func keeps(_ site: String, domains: [String]) -> Bool {
        let site = site.lowercased()
        return domains.contains { site == $0 || site.hasSuffix("." + $0) || $0.hasSuffix("." + site) }
    }

    /// Removes every site's cookies and storage except the allowed ones.
    @MainActor
    static func prune(_ store: WKWebsiteDataStore = .default(), keeping domains: [String] = domains) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let doomed = records.filter { !keeps($0.displayName, domains: domains) }
        guard !doomed.isEmpty else { return }
        await store.removeData(ofTypes: types, for: doomed)
        VoiceSessionController.appLog("browser_pruned sites=\(doomed.count) kept=\(records.count - doomed.count)")
    }

    /// Signs out of one site (or all of them with nil).
    @MainActor
    static func signOut(of domain: String?, store: WKWebsiteDataStore = .default()) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let doomed = domain.map { d in records.filter { keeps($0.displayName, domains: [d]) } } ?? records
        await store.removeData(ofTypes: types, for: doomed)
    }
}

/// Settings row that opens the list.
struct BrowserSignInsLink: View {
    @AppStorage(BrowserSignIns.key) private var saved = BrowserSignIns.encode(BrowserSignIns.defaultDomains)

    var body: some View {
        NavigationLink {
            BrowserSignInsView()
        } label: {
            let count = BrowserSignIns.decode(saved).count
            LabeledContent("Stay signed in", value: count == 1 ? "1 site" : "\(count) sites")
        }
        .accessibilityIdentifier("browser-sign-ins-link")
    }
}

/// The allowed sites: add, swipe to remove (which also signs you out), sign out of everything.
struct BrowserSignInsView: View {
    @AppStorage(BrowserSignIns.key) private var saved = BrowserSignIns.encode(BrowserSignIns.defaultDomains)
    @State private var draft = ""
    @State private var confirmSignOut = false

    private var domains: [String] { BrowserSignIns.decode(saved) }

    var body: some View {
        Form {
            Section {
                ForEach(domains, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        let removed = offsets.map { domains[$0] }
                        var list = domains
                        list.remove(atOffsets: offsets)
                        saved = BrowserSignIns.encode(list)
                        Task { for d in removed { await BrowserSignIns.signOut(of: d) } }
                    }
                HStack {
                    TextField("Add a site, like spotify.com", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                        .accessibilityIdentifier("browser-sign-ins-field")
                    Button("Add", action: add)
                        .disabled(BrowserSignIns.normalize(draft) == nil)
                }
            } footer: {
                Text("The browser keeps you signed in to these sites (and their subdomains). Every other site's cookies are deleted when the browser closes. \(Agent.name) can browse these sites while you're signed in, but never types passwords.")
            }
            Section {
                Button("Sign Out of All Sites", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out of every site in the browser?", isPresented: $confirmSignOut,
                                        titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { Task { await BrowserSignIns.signOut(of: nil) } }
                    }
            }
        }
        .navigationTitle("Stay signed in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func add() {
        guard let domain = BrowserSignIns.normalize(draft) else { return }
        if !domains.contains(domain) { saved = BrowserSignIns.encode(domains + [domain]) }
        draft = ""
    }
}
