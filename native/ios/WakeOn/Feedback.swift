import AVFoundation
import Contacts
import CoreLocation
import EventKit
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

    static var build: String { AppBuild.text }

    static func body(feedback: String, context: String, app: String = build, warnings: [String] = []) -> [String: Any] {
        ["feedback": feedback.trimmingCharacters(in: .whitespacesAndNewlines),
         "context": context.trimmingCharacters(in: .whitespacesAndNewlines), "app": app, "warnings": warnings]
    }

    /// Keeps a copy on the iPhone, then sends it with an invite code. Returns the tool's output.
    static func send(feedback: String, context: String, credential: String?, server: URL? = LobbyServer.url,
                     warnings: [String] = []) async -> String {
        let body = body(feedback: feedback, context: context, warnings: warnings)
        guard !(body["feedback"] as? String ?? "").isEmpty else { return emptyText }
        keep(body)
        guard let credential, LobbyServer.isInviteCode(credential), let server,
              JSONSerialization.isValidJSONObject(body),
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
        guard JSONSerialization.isValidJSONObject(entry),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
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

/// What the app is warning about or holding back at a moment, attached to feedback so a report
/// like "the connection was bad" or "it forgot" comes with the state behind it.
enum AppWarnings {
    struct State {
        var online = true
        var interface = "wifi"
        var connection: CallConnection.State = .good
        var roundTripMs: Double?
        var voiceNoteWaiting = false
        var chatTokens = 0
        var muted = false
        var callError: String?
        var listenerError: String?
        var lowPower = false
        var thermal: ProcessInfo.ThermalState = .nominal
        /// Permissions the user said no to ("location", "contacts").
        var denied: [String] = []
    }

    static func list(_ state: State) -> [String] {
        var warnings: [String] = []
        if !state.online { warnings.append("No internet connection") }
        switch state.connection {
        case .lost: warnings.append("Call connection lost")
        case .weak: warnings.append("Weak call connection" + (state.roundTripMs.map { String(format: " (round trip %.0f ms)", $0) } ?? ""))
        case .good: break
        }
        if state.voiceNoteWaiting { warnings.append("Voice note waiting to be sent") }
        if state.chatTokens > ChatTokens.limit {
            warnings.append("Chat is \(ChatTokens.label(state.chatTokens)): resumed calls leave out the oldest lines (limit \(ChatTokens.label(ChatTokens.limit)))")
        }
        if state.muted { warnings.append("Microphone muted in the call") }
        if let error = state.callError, !error.isEmpty { warnings.append("Call error shown: \(error)") }
        if let error = state.listenerError, !error.isEmpty { warnings.append("Listener error shown: \(error)") }
        if state.lowPower { warnings.append("Low Power Mode on") }
        switch state.thermal {
        case .serious: warnings.append("iPhone is hot (thermal state serious)")
        case .critical: warnings.append("iPhone is hot (thermal state critical)")
        default: break
        }
        if !state.denied.isEmpty { warnings.append("Access turned off: \(state.denied.joined(separator: ", "))") }
        if !warnings.isEmpty, state.online { warnings.append("Network: \(state.interface)") }
        return warnings
    }

    @MainActor static func current() -> [String] {
        let voice = VoiceSessionController.shared
        let network = NetworkPath.shared
        var denied: [String] = []
        if AVAudioApplication.shared.recordPermission == .denied { denied.append("microphone") }
        if [.denied, .restricted].contains(CLLocationManager().authorizationStatus) { denied.append("location") }
        if [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) { denied.append("calendar") }
        if [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder)) { denied.append("reminders") }
        if [.denied, .restricted].contains(CNContactStore.authorizationStatus(for: .contacts)) { denied.append("contacts") }
        return list(State(online: network.isUp, interface: network.interface, connection: voice.connection,
                          roundTripMs: voice.roundTripMs, voiceNoteWaiting: voice.voiceNote != nil,
                          chatTokens: voice.threadTokens, muted: voice.muted, callError: voice.error,
                          listenerError: WakeController.shared.error,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          thermal: ProcessInfo.processInfo.thermalState, denied: denied))
    }
}

/// Which build this is, for feedback and Settings: "0.1.0 (202611261831) · 4696310".
/// The commit comes from `PIXIE_COMMIT`, set by testflight.sh and deploy-phone.py (with
/// "-dirty" when native/ios had uncommitted changes); builds from Xcode leave it out.
enum AppBuild {
    static func text(info: [String: Any]) -> String {
        var text = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        if let commit = info["PixieCommit"] as? String, !commit.isEmpty { text += " · \(commit)" }
        #if DEBUG
        text += " · debug"
        #endif
        return text
    }

    static var text: String { text(info: Bundle.main.infoDictionary ?? [:]) }
}
