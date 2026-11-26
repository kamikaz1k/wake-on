import Foundation

/// Pixie's send_feedback tool: when the user asks, their feedback about Pixie (a bug, something
/// it got wrong, an idea) goes to the Pixie server for the developer to review
/// (`server/scripts/feedback.mjs`), with Pixie's short note on what happened and the app's
/// build. Only calls with an invite code can send it; it's also kept on the iPhone
/// (`Documents/feedback.jsonl`) so nothing is lost when it can't be sent.
enum Feedback {
    static let toolName = "send_feedback"

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Send the user's feedback about Pixie to its developer for review: a bug, something Pixie got wrong, a missing feature, an idea or praise.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "feedback": ["type": "string", "description": "The user's feedback, in their own words."],
                "context": ["type": "string", "description": "A short note on what happened in this call that the feedback is about, or an empty string."],
            ] as [String: Any],
            "required": ["feedback", "context"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    When the user wants to give feedback about Pixie or report a problem with it ("send feedback", \
    "tell the developer", "report this", "that was wrong, let them know"), call send_feedback with \
    their feedback in their own words and a short note on what happened in this call that it's \
    about. If it isn't clear what they want to say, ask first. Send only what they asked to send, \
    then tell them in a few words that it was sent.
    """

    static let sentText = "Feedback sent to the developer. Tell the user in a few words. The call goes on."
    static let keptText = "Feedback is only sent to the developer from calls with an invite code, so it was saved on this iPhone instead. Tell the user."
    static let failedText = "Couldn't send the feedback just now; it was saved on this iPhone. Tell the user to try again later."
    static let emptyText = "No feedback to send. Ask the user what they'd like to say."

    /// "1.0 (202611260320)".
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    static func body(feedback: String, context: String, app: String = build) -> [String: Any] {
        ["feedback": feedback.trimmingCharacters(in: .whitespacesAndNewlines),
         "context": context.trimmingCharacters(in: .whitespacesAndNewlines), "app": app]
    }

    /// Keeps a copy on the iPhone, then sends it with an invite code. Returns the tool's output.
    static func send(feedback: String, context: String, credential: String?, server: URL? = LobbyServer.url) async -> String {
        let body = body(feedback: feedback, context: context)
        guard !(body["feedback"] as? String ?? "").isEmpty else { return emptyText }
        keep(body)
        guard let credential, LobbyServer.isInviteCode(credential), let server,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return keptText }
        var request = URLRequest(url: server.appendingPathComponent("v1/feedback"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        VoiceSessionController.appLog("feedback status=\(status)")
        return status == 200 ? sentText : failedText
    }

    private static func keep(_ body: [String: Any]) {
        var entry = body
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = docs.appendingPathComponent("feedback.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
