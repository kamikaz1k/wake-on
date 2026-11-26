import Foundation

/// How long a chat is in tokens, estimated. A resumed call carries the chat's transcript in its
/// instructions, up to `limit`; past that the oldest lines are left out. Pixie's memory keeps
/// what lasts, so this isn't shown to the user; feedback reports it (`AppWarnings`).
enum ChatTokens {
    /// Tokens of transcript a resumed call carries (about 16,000 characters). Both models get
    /// it, so it's paid twice per answer (mostly from the cache).
    static let limit = 4000

    /// About 4 characters per token for English; there is no tokenizer on the phone.
    static func estimate(_ text: String) -> Int { (text.count + 3) / 4 }

    /// One transcript line as a resumed call sees it ("User: …" or "Pixie: …").
    static func line(_ line: ChatLog.Line) -> String {
        "\(line.speaker == "You" ? "User" : Agent.name): \(line.text)"
    }

    static func estimate(_ lines: [ChatLog.Line]) -> Int {
        lines.reduce(0) { $0 + estimate(line($1)) }
    }

    /// "~850 tokens", "~1.4k tokens".
    static func label(_ tokens: Int) -> String {
        tokens < 1000 ? "~\(tokens) tokens" : String(format: "~%.1fk tokens", Double(tokens) / 1000)
    }
}
