import Foundation

/// Wake On's call server (`server/` in the repo, a Cloudflare Worker). Friends on TestFlight
/// enter an invite code instead of an OpenAI key; calls with a code are set up through the
/// server, which adds the real key, so the key is never in the app. The server takes the
/// same request as OpenAI, so only the address changes; the call's audio still goes straight
/// to OpenAI.
enum LobbyServer {
    /// The deployed worker's address (`scripts/setup.sh` prints it). Nil until deployed.
    static let url: URL? = nil

    /// OpenAI keys start with "sk-"; anything else saved in Settings is an invite code.
    static func isInviteCode(_ credential: String) -> Bool {
        !credential.hasPrefix("sk-")
    }

    /// Where to set up a call with this credential: OpenAI for a key, the server for a code.
    static func endpoint(for credential: String, openAI: URL, server: URL? = url) throws -> URL {
        guard isInviteCode(credential) else { return openAI }
        guard let server else { throw VoiceError.message("This build has no Lobby server for invite codes. Use an OpenAI key.") }
        return server.appendingPathComponent("v1/live/sessions")
    }
}
