import SwiftUI

/// How long a chat is in tokens, estimated. A resumed call carries the chat's transcript in its
/// instructions, up to `limit`; past that the oldest lines are left out (until compaction or
/// memory exists), so the app warns as a chat gets close.
enum ChatTokens {
    /// Tokens of transcript a resumed call carries (about 6,000 characters).
    static let limit = 1500
    /// Warn from here: one or two more exchanges may pass the limit.
    static let warnAt = 1200

    enum Level { case ok, long, truncated }

    /// About 4 characters per token for English; there is no tokenizer on the phone.
    static func estimate(_ text: String) -> Int { (text.count + 3) / 4 }

    /// One transcript line as a resumed call sees it ("User: …" or "Pixie: …").
    static func line(_ line: ChatLog.Line) -> String {
        "\(line.speaker == "You" ? "User" : Agent.name): \(line.text)"
    }

    static func estimate(_ lines: [ChatLog.Line]) -> Int {
        lines.reduce(0) { $0 + estimate(line($1)) }
    }

    static func level(_ tokens: Int) -> Level {
        tokens > limit ? .truncated : tokens >= warnAt ? .long : .ok
    }

    /// "~850 tokens", "~1.4k tokens".
    static func label(_ tokens: Int) -> String {
        tokens < 1000 ? "~\(tokens) tokens" : String(format: "~%.1fk tokens", Double(tokens) / 1000)
    }

    /// The warning to show, or nil while the chat is short.
    static func warning(_ tokens: Int) -> String? {
        switch level(tokens) {
        case .ok: nil
        case .long: "This chat is getting long (\(label(tokens)) of \(label(limit))). Past that, resuming leaves out the oldest parts."
        case .truncated: "Long chat (\(label(tokens))): resuming keeps only the newest \(label(limit))."
        }
    }
}

/// The warning as a standard label, for the top of a chat or above call controls.
struct ChatLengthWarning: View {
    let tokens: Int

    var body: some View {
        if let text = ChatTokens.warning(tokens) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("chat-length-warning")
        }
    }
}
