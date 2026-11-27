import Foundation

/// Checks an invite code or OpenAI key before it's saved ("Verify and Save"). Neither check
/// starts a call or costs anything: codes go to the Pixie server's /v1/check, keys ask OpenAI
/// for its model list.
enum CredentialCheck {
    enum Outcome: Equatable {
        /// Works: save it.
        case valid(String)
        /// Saved, but with something to know (couldn't check offline, account out of credit…).
        case savedWithWarning(String)
        /// Not saved: what's wrong and how to fix it. The text stays in the field.
        case rejected(String)

        var saves: Bool {
            if case .rejected = self { return false }
            return true
        }
        var message: String {
            switch self {
            case .valid(let text), .savedWithWarning(let text), .rejected(let text): text
            }
        }
    }

    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let openAIModels = URL(string: "https://api.openai.com/v1/models")!

    /// "name-1-abcdefghjkmn": a name, the signing key's number and a 12-letter signature.
    static func looksLikeInviteCode(_ text: String) -> Bool {
        text.lowercased().range(of: #"^[a-z0-9]+-[0-9]+-[0-9a-z]{12}$"#, options: .regularExpression) != nil
    }

    static func check(_ raw: String, server: URL? = LobbyServer.url,
                      send: Send = { try await URLSession.shared.data(for: $0) }) async -> Outcome {
        let credential = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { return .rejected("Enter an invite code or an OpenAI key.") }
        if LobbyServer.isInviteCode(credential) {
            guard looksLikeInviteCode(credential) else {
                return .rejected("That doesn't look like an invite code (like alex-1-7k2mq9xd4r8w) "
                                 + "or an OpenAI key (starting with sk-). Check it was copied in full.")
            }
            guard let server else { return .rejected("This build can't use invite codes. Use an OpenAI key.") }
            var request = URLRequest(url: server.appendingPathComponent("v1/check"), timeoutInterval: 8)
            request.httpMethod = "POST"
            LobbyServer.authorize(&request, credential: credential)
            return await run(request, send: send, interpret: inviteOutcome)
        }
        var request = URLRequest(url: openAIModels, timeoutInterval: 8)
        LobbyServer.authorize(&request, credential: credential)
        return await run(request, send: send, interpret: keyOutcome)
    }

    private static func run(_ request: URLRequest, send: Send,
                            interpret: (Int, String?) -> Outcome) async -> Outcome {
        do {
            let (data, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (error?["type"] as? String)
            return interpret(status, code)
        } catch {
            return .savedWithWarning("Saved, but couldn't check it: no connection. "
                                     + "It's checked again when you start a chat.")
        }
    }

    static func inviteOutcome(status: Int, code: String?) -> Outcome {
        switch (status, code) {
        case (200, _):
            return .valid("Invite code works. Saved.")
        case (_, "expired_code"), (_, "revoked_code"):
            return .rejected("This invite code doesn't work anymore. Ask for a new one.")
        case (401, _):
            return .rejected("That invite code isn't right. Check for typos, or ask for it again.")
        default:
            return .savedWithWarning("Saved, but the \(Agent.name) server couldn't check it right now. "
                                     + "It's checked again when you start a chat.")
        }
    }

    static func keyOutcome(status: Int, code: String?) -> Outcome {
        switch (status, code) {
        case (200, _):
            return .valid("OpenAI accepted the key. Saved.")
        case (401, _):
            return .rejected("OpenAI didn't accept this key. Check it was copied in full, "
                             + "or make a new one at platform.openai.com.")
        case (429, "insufficient_quota"):
            return .savedWithWarning("Saved, but OpenAI says this account is out of credit, so calls "
                                     + "will fail until billing is set up.")
        case (403, _):
            // Restricted keys may not list models but can still make calls.
            return .savedWithWarning("Saved. OpenAI accepted the key, but it can't list models, "
                                     + "so whether calls work is checked when you start a chat.")
        default:
            return .savedWithWarning("Saved, but OpenAI couldn't check it right now. "
                                     + "It's checked again when you start a chat.")
        }
    }
}
