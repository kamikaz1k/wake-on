import Foundation

/// Wake On's call server (`server/` in the repo, a Cloudflare Worker). Friends on TestFlight
/// enter an invite code instead of an OpenAI key; calls with a code are set up through the
/// server, which adds the real key, so the key is never in the app. The server takes the
/// same request as OpenAI, so only the address changes; the call's audio still goes straight
/// to OpenAI.
enum LobbyServer {
    /// The deployed worker (`server/scripts/setup.sh` prints its address).
    static let url: URL? = URL(string: "https://wake-on.kamikaz1k.workers.dev")

    /// OpenAI keys start with "sk-"; anything else saved in Settings is an invite code.
    static func isInviteCode(_ credential: String) -> Bool {
        !credential.hasPrefix("sk-")
    }

    /// Set when the server turns the saved code down for good (wrong, expired or revoked), so
    /// Settings can say a new code is needed. Cleared when a code or key is saved or removed.
    static let needsNewCodeKey = "lobby.needsNewCode"

    /// What to tell the user when a call with an invite code is turned down, and whether the
    /// code itself is the problem (Settings then asks for a new one). Nil: show the raw error.
    static func problem(status: Int, code: String?, now: Date = Date(),
                        calendar: Calendar = .current) -> (message: String, needsNewCode: Bool)? {
        switch code {
        case "invalid_code", "missing_code":
            return ("That invite code isn't right. Check it under Settings › Invite Code or Key.", true)
        case "expired_code", "revoked_code":
            return ("This invite code doesn't work anymore. Ask for a new one and enter it under "
                    + "Settings › Invite Code or Key.", true)
        case "daily_limit":
            return ("You've used today's calls. More at \(resetTime(now: now, calendar: calendar)).", false)
        case "global_limit":
            return ("\(Agent.name) is out of calls for today. More at \(resetTime(now: now, calendar: calendar)).", false)
        default:
            // A 401 that isn't about the code means the server's own OpenAI key was refused.
            return status == 401 ? ("\(Agent.name)'s server can't reach OpenAI right now. Try again later.", false) : nil
        }
    }

    /// The server's day ends at midnight UTC: that moment in the user's own time, e.g. "7:00 PM".
    static func resetTime(now: Date, calendar: Calendar = .current) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now
        let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                      calendar: calendar, timeZone: calendar.timeZone)
        return midnight.formatted(format)
    }

    /// Where to set up a call with this credential: OpenAI for a key, the server for a code.
    static func endpoint(for credential: String, openAI: URL, server: URL? = url) throws -> URL {
        guard isInviteCode(credential) else { return openAI }
        guard let server else { throw VoiceError.message("This build has no \(Agent.name) server for invite codes. Use an OpenAI key.") }
        return server.appendingPathComponent("v1/live/sessions")
    }
}
