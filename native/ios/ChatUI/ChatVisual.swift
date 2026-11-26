import SwiftUI
import UIKit
import WebKit

/// Pixie's show_visual tool: the backend model writes one self-contained HTML page (a chart, a
/// table, a diagram, a small app) and the chat shows it in a web view while the call goes on.
///
/// The page runs in WebKit's own sandboxed process with a throwaway data store and no bridge
/// into the app, so it can't reach the app's files, the Keychain or the API key. It may load
/// from the web (CDN libraries, public APIs). Links open in Safari; the page itself can't
/// navigate away. What a page could still do is send what the model put in it somewhere, so
/// every page is kept in the call capture for review.
enum ShowVisual {
    static let toolName = "show_visual"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Show the user something visual on their phone screen: a chart, table, diagram, timeline or small interactive page. The call continues while it is shown.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "A short title, a few words."],
                "html": ["type": "string", "description": "One complete, self-contained HTML document."],
                "icon": ["type": "string", "description": "An SF Symbol name for the page if the user saves it as an app, such as cloud.sun or percent."],
                "refresh": ["type": "string", "description": "If the page shows data that goes stale (weather, news, scores, prices, schedules), the request that remakes it with fresh data, naming any place, such as \"This week's weather in Toronto\". Empty for pages that work on their own (calculators, checklists, converters, games)."],
            ],
            "required": ["title", "html", "icon", "refresh"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks to see, show, draw, chart, map or visualize something, or a table or chart \
    would answer far better than speech, call show_visual with a title and one complete HTML \
    document. Look up the data first, and gather enough to fill the page (for weather: conditions, \
    highs and lows, chance of rain; for products: prices and the specs that differ). Match the \
    polish to the content. When there's data worth seeing (a forecast, prices or specs to compare, \
    rankings, numbers over time), make it look like a polished phone widget: a headline card with \
    the key figure large, then rows that show the numbers as shapes, such as a low-to-high bar per \
    day on a shared scale or a bar per price, with a small icon or emoji per row. Use rounded cards \
    on a soft background, one accent color, muted secondary text and tabular numbers. For a few \
    facts or a short list, one clean card is enough. Fit a phone: width 100%, no fixed widths, \
    readable at 16px, and support light and dark mode with prefers-color-scheme. Inline SVG and \
    CSS are best; you may load libraries from cdn.jsdelivr.net or cdnjs.cloudflare.com. Keep the \
    HTML compact, about 5 KB at most, so it appears quickly. After it is shown, reply in one \
    sentence saying what is on their screen. The user can save a page as an app on their phone, \
    so make small tools (calculators, checklists, trackers) work fully on their own, keeping any \
    data they enter in localStorage.
    """

    /// Title and HTML from the tool's arguments, which may still be streaming in (a JSON
    /// prefix): strings are read up to where the text has got to.
    static func visual(fromArguments json: String, complete: Bool) -> ChatItem.Visual? {
        guard let html = stringPrefix(of: "html", in: json), !(complete && html.isEmpty) else { return nil }
        var visual = ChatItem.Visual(title: stringPrefix(of: "title", in: json) ?? "", html: html, complete: complete)
        if complete {
            visual.icon = stringPrefix(of: "icon", in: json) ?? ""
            visual.refresh = stringPrefix(of: "refresh", in: json) ?? ""
        }
        return visual
    }

    /// The (possibly unfinished) value of a top-level string field in a JSON prefix.
    static func stringPrefix(of key: String, in json: String) -> String? {
        // The first match is the key: the same text inside an earlier string would be escaped.
        guard let range = json.range(of: "\"\(key)\"") else { return nil }
        let chars = Array(json.utf16)
        var i = json.utf16.distance(from: json.startIndex, to: range.upperBound)
        func skipSpace() { while i < chars.count, [0x20, 0x0A, 0x0D, 0x09].contains(chars[i]) { i += 1 } }
        skipSpace()
        guard i < chars.count, chars[i] == 0x3A else { return nil } // ':'
        i += 1
        skipSpace()
        guard i < chars.count, chars[i] == 0x22 else { return nil } // '"'
        i += 1
        var out: [UInt16] = []
        while i < chars.count {
            let c = chars[i]
            if c == 0x22 { break }
            if c != 0x5C { out.append(c); i += 1; continue } // not '\'
            guard i + 1 < chars.count else { break }
            let e = chars[i + 1]
            switch e {
            case 0x6E: out.append(0x0A) // n
            case 0x74: out.append(0x09) // t
            case 0x72: out.append(0x0D) // r
            case 0x62: out.append(0x08) // b
            case 0x66: out.append(0x0C) // f
            case 0x75: // u
                guard i + 5 < chars.count,
                      let code = UInt16(String(decoding: chars[i + 2...i + 5], as: UTF16.self), radix: 16)
                else { return String(decoding: out, as: UTF16.self) }
                out.append(code)
                i += 6
                continue
            default: out.append(e) // \" \\ \/
            }
            i += 2
        }
        return String(decoding: out, as: UTF16.self)
    }
}

/// Saves a page as an app (the app's MiniAppStore; Chat Lab has none, so no Save button).
@MainActor
protocol VisualSaver: AnyObject {
    func isSaved(_ visual: ChatItem.Visual) -> Bool
    /// True once it's saved.
    func save(_ visual: ChatItem.Visual) -> Bool
}

private struct VisualSaverKey: EnvironmentKey {
    static let defaultValue: VisualSaver? = nil
}

extension EnvironmentValues {
    var visualSaver: VisualSaver? {
        get { self[VisualSaverKey.self] }
        set { self[VisualSaverKey.self] = newValue }
    }
}

/// A show_visual row: the page in a small preview, tap to open it full size.
struct ChatVisualRow: View {
    let tool: ChatItem.Tool
    let visual: ChatItem.Visual
    @State private var open = false
    @Environment(\.visualSaver) private var saver
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open = true } label: {
                HStack(spacing: 8) {
                    if visual.complete {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(.tint)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(visual.title.isEmpty ? "Visual" : visual.title)
                        .font(.subheadline.weight(.medium))
                        .shimmering(!visual.complete)
                    Spacer()
                    if !visual.complete {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(visual.html.utf8.count), countStyle: .file))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-visual-open")
            // The preview doesn't take touches, so the chat scrolls over it; the full view does.
            VisualWebView(html: visual.html, complete: visual.complete)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
                .onTapGesture { open = true }
                .accessibilityIdentifier("chat-visual-preview")
            if let saver, visual.complete {
                Button {
                    saved = saver.save(visual)
                } label: {
                    Label(saved ? "Saved to My Apps" : "Save as App", systemImage: saved ? "checkmark" : "plus.app")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(saved)
                .onAppear { saved = saver.isSaved(visual) }
                .accessibilityIdentifier("chat-visual-save")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .sheet(isPresented: $open) {
            NavigationStack {
                VisualWebView(html: visual.html, complete: visual.complete)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(visual.title.isEmpty ? "Visual" : visual.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { open = false }.accessibilityIdentifier("chat-visual-done")
                        }
                    }
            }
        }
    }
}

/// A WKWebView showing one page from show_visual. While the page is still being written it is
/// reloaded at most twice a second, so it fills in as it streams.
///
/// A saved app (`storage` set) gets an address of its own, `pixie-app://<id>/`, and a data store
/// kept for it alone, so what it saves in localStorage stays between launches and apart from
/// other apps.
struct VisualWebView: UIViewRepresentable {
    let html: String
    var complete = true
    var storage: UUID? = nil

    static let appScheme = "pixie-app"

    func makeCoordinator() -> Coordinator { Coordinator(storage: storage) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let storage {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storage)
            config.setURLSchemeHandler(context.coordinator.pages, forURLScheme: Self.appScheme)
        } else {
            config.websiteDataStore = .nonPersistent()
        }
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        #if DEBUG
        view.isInspectable = true
        #endif
        context.coordinator.load(html, complete: complete, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, complete: complete, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let storage: UUID?
        let pages = AppPages()
        init(storage: UUID?) { self.storage = storage }
        private var loaded: String?
        private var pending: String?
        private var lastLoad = Date.distantPast

        func load(_ html: String, complete: Bool, in view: WKWebView) {
            guard html != loaded else { return }
            let wait = 0.5 - Date().timeIntervalSince(lastLoad)
            if complete || wait <= 0 {
                pending = nil
                show(html, in: view)
                return
            }
            let scheduled = pending != nil
            pending = html
            guard !scheduled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak view] in
                guard let self, let view, let html = self.pending else { return }
                self.pending = nil
                self.show(html, in: view)
            }
        }

        private func show(_ html: String, in view: WKWebView) {
            loaded = html
            lastLoad = Date()
            if let storage, let url = URL(string: "\(VisualWebView.appScheme)://\(storage.uuidString.lowercased())/") {
                pages.html = html
                view.load(URLRequest(url: url))
            } else {
                view.loadHTMLString(html, baseURL: nil)
            }
        }

        /// The page is the one we loaded: links open in Safari, and the page can't replace
        /// itself with another site. Frames inside it (maps, embeds) may load.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            let isOurPage = url?.scheme == "about" || url?.scheme == VisualWebView.appScheme
            if action.targetFrame?.isMainFrame == false || isOurPage {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated, let url, ["http", "https"].contains(url.scheme) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// window.open and target=_blank links open in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme) { UIApplication.shared.open(url) }
            return nil
        }
    }
}

/// Serves a saved app's page at its own address. Anything else under it is not found.
final class AppPages: NSObject, WKURLSchemeHandler {
    var html = ""

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let isPage = url.path.isEmpty || url.path == "/" || url.path == "/index.html"
        let data = Data((isPage ? html : "").utf8)
        let response = HTTPURLResponse(url: url, statusCode: isPage ? 200 : 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8",
                                                      "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A place from open_map's show mode: Google's embedded map of it, with a link out to Google
/// Maps. The preview doesn't take touches (the chat scrolls over it); tapping opens a map you
/// can pan and zoom.
struct ChatPlaceRow: View {
    let place: ChatItem.Place
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.red)
                    Text(place.title.isEmpty ? "Map" : place.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-place-open")
            VisualWebView(html: html)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
                .contentShape(Rectangle())
                .onTapGesture { open = true }
                .accessibilityIdentifier("chat-place-map")
            if let url = URL(string: place.webURL) {
                Link(destination: url) {
                    Label("Open in Google Maps", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat-place-link")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $open) {
            NavigationStack {
                VisualWebView(html: html)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(place.title.isEmpty ? "Map" : place.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { open = false }.accessibilityIdentifier("chat-place-done")
                        }
                        if let url = URL(string: place.webURL) {
                            ToolbarItem(placement: .topBarLeading) {
                                Link(destination: url) { Label("Open in Google Maps", systemImage: "arrow.up.right.square") }
                            }
                        }
                    }
            }
        }
    }

    /// The embed fills the page; its own "View larger map" link opens Google Maps too.
    private var html: String {
        let src = place.embedURL.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe src="\(src)" allowfullscreen referrerpolicy="no-referrer-when-downgrade"></iframe></body></html>
        """
    }
}
