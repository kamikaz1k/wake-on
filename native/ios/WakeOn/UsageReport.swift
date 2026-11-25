import Foundation

/// What a call with an invite code used, sent to the Pixie server at hang-up so it can add it
/// up per person per day (`server/scripts/usage.mjs` prints it). The voice model is billed by
/// the second and only reports seconds; the backend reports tokens. Calls with an OpenAI key
/// send nothing. Best effort: a report that fails is dropped.
enum UsageReport {
    struct Tokens: Equatable {
        var input = 0, cached = 0, output = 0

        init(input: Int = 0, cached: Int = 0, output: Int = 0) {
            self.input = input; self.cached = cached; self.output = output
        }

        /// The usage in a backend `response.completed` event.
        init?(_ json: [String: Any]) {
            guard let usage = ((json["event"] as? [String: Any])?["response"] as? [String: Any])?["usage"] as? [String: Any],
                  let input = usage["input_tokens"] as? Int else { return nil }
            self.input = input
            cached = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            output = usage["output_tokens"] as? Int ?? 0
        }

        mutating func add(_ other: Tokens) {
            input += other.input; cached += other.cached; output += other.output
        }
    }

    static func body(seconds: Double, tokens: Tokens) -> [String: Any] {
        ["seconds": (seconds * 10).rounded() / 10, "input_tokens": tokens.input,
         "cached_tokens": tokens.cached, "output_tokens": tokens.output]
    }

    static func send(seconds: Double, tokens: Tokens, credential: String, server: URL? = LobbyServer.url) {
        guard LobbyServer.isInviteCode(credential), let server,
              let data = try? JSONSerialization.data(withJSONObject: body(seconds: seconds, tokens: tokens)) else { return }
        var request = URLRequest(url: server.appendingPathComponent("v1/usage"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        Task.detached {
            let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            VoiceSessionController.appLog("usage_report status=\(status) seconds=\(seconds) input=\(tokens.input) output=\(tokens.output)")
        }
    }
}
