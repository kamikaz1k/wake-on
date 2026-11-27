import SwiftUI

/// Pixie's show_markdown tool: a link, an address, a number or a few lines of text shown in the
/// chat, for anything the user wants to read, tap or copy rather than hear. Before it, Pixie
/// had no way to hand over a link and told the user it couldn't (2026-11-27).
enum ShowMarkdown {
    static let toolName = "show_markdown"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Show the user text on their phone screen: a link, an address, a phone number, a recipe, steps or anything they want to read, tap or copy. Markdown links and bold work. The call continues while it is shown.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "A short title, a few words, or an empty string."],
                "markdown": ["type": "string", "description": "The text, in Markdown. Write links as [title](https://…)."],
            ],
            "required": ["title", "markdown"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user asks for a link, an address, a number or text to read or copy, or an answer \
    has a link worth keeping (an article, a page, a product), call show_markdown with it, links \
    written as [title](url) with the real address you found. Then say in one sentence that it's \
    on their screen. Never say you can't send a link or text.
    """

    static func markdown(fromArguments json: String) -> ChatItem.Markdown? {
        guard let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = args["markdown"] as? String, !text.isEmpty else { return nil }
        return ChatItem.Markdown(title: args["title"] as? String ?? "", text: text)
    }

    /// Inline Markdown (links, bold, italics, code) with the line breaks kept, so lists and
    /// paragraphs still read as written. Plain text if it doesn't parse.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The page a browser step ended on, from the tool's result ("Page: …" and "Address: …").
enum BrowserPage {
    static func from(output: String) -> ChatItem.Source? {
        var title = "", address = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Page: ") { title = String(line.dropFirst(6)) }
            if line.hasPrefix("Address: ") { address = String(line.dropFirst(9)) }
        }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        return ChatItem.Source(title: title.isEmpty ? (url.host ?? address) : title, url: address)
    }
}

extension EnvironmentValues {
    /// Opens a page in the app's own browser (Pixie's, in Wake On). Unset: Safari.
    @Entry var chatOpenPage: ((URL) -> Void)? = nil
}

/// A page a browser step was on: tap to open it again.
struct ChatPageLink: View {
    let title: String
    let url: URL
    @Environment(\.chatOpenPage) private var openPage
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openPage.map { $0(url) } ?? openURL(url) } label: {
            Label(title, systemImage: "safari")
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("chat-page-link")
    }
}

/// show_markdown's card: the title, then the text, selectable, with tappable links.
struct ChatMarkdownRow: View {
    let markdown: ChatItem.Markdown
    @Environment(\.chatOpenPage) private var openPage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !markdown.title.isEmpty {
                Label(markdown.title, systemImage: "doc.text").font(.subheadline.weight(.medium))
            }
            Text(ShowMarkdown.attributed(markdown.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.openURL, OpenURLAction { url in
            guard let openPage, url.scheme?.hasPrefix("http") == true else { return .systemAction }
            openPage(url)
            return .handled
        })
        .accessibilityIdentifier("chat-markdown")
    }
}
