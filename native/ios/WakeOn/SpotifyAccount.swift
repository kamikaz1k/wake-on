import AuthenticationServices
import SwiftUI
import CryptoKit
import Foundation
import Security
import UIKit
import UserNotifications

/// The user's own Spotify account, connected in Settings, so Pixie can pause, resume and skip
/// Spotify through the Web API. Works in every build (TestFlight too, unlike MediaControl's
/// private API), from the background and with the phone locked: it's an HTTPS request to
/// Spotify, which controls whichever device is playing.
///
/// Sign-in is OAuth with PKCE (no client secret on the phone) through Spotify's login page.
/// Spotify's app "Pixie" is in Development Mode: only Premium accounts added under User
/// Management in the developer dashboard can use it (at most 5).
@MainActor
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()

    static let clientID = "04743c7fada64f6eb4a31985c1bb3ebb"
    static let redirect = "wakeon://spotify-callback"
    static let scopes = "user-read-playback-state user-modify-playback-state"
    /// Readable without the main actor: LiveVoiceConfig decides whether to offer control_media.
    static let connectedKey = "spotify.connected"
    nonisolated static var isConnected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }

    @Published private(set) var connected = SpotifyAccount.isConnected
    @Published private(set) var name: String? = UserDefaults.standard.string(forKey: "spotify.name")
    @Published private(set) var busy = false
    @Published var problem: String?

    private var authSession: ASWebAuthenticationSession?
    private let anchor = Anchor()

    // MARK: Connect

    func connect() {
        guard !busy else { return }
        problem = nil
        busy = true
        let verifier = Self.randomVerifier()
        let state = UUID().uuidString
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "state", value: state),
        ]
        let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "wakeon") { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.busy = false
                    return
                }
                let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }
                guard error == nil, value("state") == state, let code = value("code") else {
                    self.finish(problem: value("error") == "access_denied" ? nil : "Spotify didn't connect. Try again.")
                    return
                }
                await self.exchange(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = anchor
        authSession = session
        if !session.start() { finish(problem: "Couldn't open Spotify's sign-in.") }
    }

    func disconnect() {
        SpotifyTokens.delete()
        UserDefaults.standard.removeObject(forKey: "spotify.name")
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        connected = false
        name = nil
        problem = nil
        VoiceSessionController.appLog("spotify disconnected")
    }

    private func exchange(code: String, verifier: String) async {
        do {
            let tokens = try await Self.tokenRequest([
                "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                "client_id": Self.clientID, "code_verifier": verifier,
            ], previous: nil)
            try SpotifyTokens.save(tokens)
            // Who signed in, and whether Spotify lets this account use the app at all.
            let (status, body) = try await Self.api("GET", "/v1/me")
            if status == 403 {
                SpotifyTokens.delete()
                return finish(problem: Self.notAllowedText)
            }
            let me = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let shown = (me?["display_name"] as? String) ?? (me?["id"] as? String) ?? "Connected"
            UserDefaults.standard.set(shown, forKey: "spotify.name")
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
            name = shown
            connected = true
            VoiceSessionController.appLog("spotify connected status=\(status)")
            finish(problem: nil)
        } catch {
            SpotifyTokens.delete()
            finish(problem: "Spotify didn't connect: \(error.localizedDescription)")
        }
    }

    private func finish(problem: String?) {
        if let problem { VoiceSessionController.appLog("spotify connect_failed \(problem)") }
        self.problem = problem
        busy = false
    }

    static let notAllowedText = "Spotify hasn't allowed this account yet. While Pixie's Spotify access is in testing, only accounts the developer adds can connect."

    // MARK: Playback

    enum Outcome: Equatable {
        case done
        case noActiveDevice
        case premiumRequired
        case notAllowed
        case signedOut
        case failed(String)

        /// What the user sees when a command after the call didn't work (nil when it did).
        var notice: String? {
            switch self {
            case .done: nil
            case .noActiveDevice: "Spotify isn't playing on any device right now. Open Spotify and press play."
            case .premiumRequired: "Spotify only lets apps control playback with Premium."
            case .notAllowed: SpotifyAccount.notAllowedText
            case .signedOut: "Spotify is disconnected. Connect it again in Pixie's Settings."
            case .failed(let why): "Spotify didn't respond (\(why))."
            }
        }
    }

    /// Spotify's Web API endpoint for each command.
    nonisolated static func endpoint(_ command: MediaControl.Command) -> (method: String, path: String) {
        switch command {
        case .pause: ("PUT", "/v1/me/player/pause")
        case .play: ("PUT", "/v1/me/player/play")
        case .next: ("POST", "/v1/me/player/next")
        case .previous: ("POST", "/v1/me/player/previous")
        }
    }

    /// Reads Spotify's error reply: 404 NO_ACTIVE_DEVICE, 403 PREMIUM_REQUIRED, or 403 for an
    /// account that isn't on the app's user list.
    nonisolated static func outcome(status: Int, body: Data) -> Outcome {
        if (200..<300).contains(status) { return .done }
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
        let reason = error?["reason"] as? String ?? ""
        let message = error?["message"] as? String ?? ""
        if status == 404 || reason == "NO_ACTIVE_DEVICE" { return .noActiveDevice }
        if reason == "PREMIUM_REQUIRED" { return .premiumRequired }
        if status == 401 { return .signedOut }
        if status == 403, message.localizedCaseInsensitiveContains("registered") || message.localizedCaseInsensitiveContains("developer") {
            return .notAllowed
        }
        // Pausing what's already paused is refused as a "restriction"; the user got what they asked.
        if status == 403, reason == "UNKNOWN" || message.localizedCaseInsensitiveContains("restriction") { return .done }
        return .failed("\(status)\(message.isEmpty ? "" : ": \(message)")")
    }

    nonisolated static func send(_ command: MediaControl.Command) async -> Outcome {
        let (method, path) = endpoint(command)
        do {
            let (status, body) = try await api(method, path)
            let result = outcome(status: status, body: body)
            VoiceSessionController.appLog("spotify_command \(command.rawValue) status=\(status) outcome=\(result)")
            return result
        } catch SpotifyTokens.Missing.signedOut {
            return .signedOut
        } catch {
            VoiceSessionController.appLog("spotify_command \(command.rawValue) error=\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Posts a notification when a command sent after the call didn't work.
    nonisolated static func notify(_ outcome: Outcome) {
        guard let text = outcome.notice else { return }
        let content = UNMutableNotificationContent()
        content.title = "Spotify"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "spotify-control", content: content, trigger: nil))
    }

    // MARK: Requests

    /// A Web API request with a fresh access token; refreshes and retries once on 401.
    nonisolated static func api(_ method: String, _ path: String) async throws -> (Int, Data) {
        var tokens = try await SpotifyTokens.fresh()
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
            if method != "GET" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                tokens = try await SpotifyTokens.refresh(tokens)
                continue
            }
            return (status, data)
        }
        return (401, Data())
    }

    nonisolated static func tokenRequest(_ form: [String: String], previous: SpotifyTokens.Value?) async throws -> SpotifyTokens.Value {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 400, json["error"] as? String == "invalid_grant" { throw SpotifyTokens.Missing.signedOut }
        guard status == 200, let access = json["access_token"] as? String else {
            throw VoiceError.message("token request failed (\(status))")
        }
        // Spotify may or may not send a new refresh token; keep the old one if not.
        guard let refresh = (json["refresh_token"] as? String) ?? previous?.refresh else {
            throw VoiceError.message("no refresh token")
        }
        let lifetime = json["expires_in"] as? Double ?? 3600
        return .init(access: access, refresh: refresh, expires: Date().addingTimeInterval(lifetime - 60))
    }

    // MARK: PKCE

    nonisolated static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
            }
        }
    }
}

/// Spotify's access and refresh tokens, in the Keychain (readable after first unlock, so a
/// command works with the phone locked).
enum SpotifyTokens {
    struct Value: Codable, Equatable {
        var access: String
        var refresh: String
        var expires: Date
    }

    enum Missing: Error { case signedOut }

    private static let service = "com.kamikaz1k.wakeon.spotify"
    private static let account = "tokens"

    static func fresh() async throws -> Value {
        guard let tokens = load() else { throw Missing.signedOut }
        return tokens.expires > Date() ? tokens : try await refresh(tokens)
    }

    static func refresh(_ tokens: Value) async throws -> Value {
        do {
            let new = try await SpotifyAccount.tokenRequest(
                ["grant_type": "refresh_token", "refresh_token": tokens.refresh, "client_id": SpotifyAccount.clientID],
                previous: tokens)
            try save(new)
            return new
        } catch Missing.signedOut {
            // The refresh token was revoked or expired: show Spotify as disconnected.
            delete()
            UserDefaults.standard.set(false, forKey: SpotifyAccount.connectedKey)
            throw Missing.signedOut
        }
    }

    static func save(_ value: Value) throws {
        delete()
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(value),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceError.message("Keychain save failed (\(status)).") }
    }

    static func load() -> Value? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// Settings › Spotify: connect the user's own account so Pixie can pause, resume and skip it.
struct SpotifySection: View {
    @ObservedObject private var account: SpotifyAccount = .shared
    @State private var confirmDisconnect = false
    @State private var signInTip = false

    var body: some View {
        Section {
            if account.connected {
                LabeledContent("Spotify", value: account.name ?? "Connected")
                Button("Disconnect Spotify", role: .destructive) { confirmDisconnect = true }
                    .accessibilityIdentifier("settings-spotify-disconnect")
            } else {
                Button {
                    signInTip = true
                } label: {
                    HStack {
                        Text("Connect Spotify")
                        if account.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(account.busy)
                .accessibilityIdentifier("settings-spotify-connect")
            }
            if let problem = account.problem {
                Text(problem).foregroundStyle(.red)
            }
        } header: { Text("Music") } footer: {
            Text("With Spotify connected, \(Agent.name) can pause, resume and skip it, on any device that's playing. Needs Spotify Premium. While this is in testing, only accounts the developer has added can connect.")
        }
        // Spotify's page offers Facebook and Google, which refuse to sign in inside apps.
        .alert("Sign in with email", isPresented: $signInTip) {
            Button("Continue") { account.connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On Spotify's page, choose Continue with email (Spotify emails you a code) or Continue with Apple. Facebook and Google sign-in don't work here.")
        }
        .confirmationDialog("Disconnect Spotify?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { account.disconnect() }
        }
    }
}
