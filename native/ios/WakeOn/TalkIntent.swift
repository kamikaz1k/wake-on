import AppIntents
import Foundation
import UIKit

/// Assign this to the Action Button (Settings › Action Button › Shortcut › Wake On › Talk to Lobby).
/// It brings the app forward, because iOS only lets a foreground app start the microphone reliably,
/// and starts the call without waiting for it to connect.
struct TalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Lobby"
    static var description = IntentDescription("Open Wake On and start a realtime voice conversation.")
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        let entered = DispatchTime.now().uptimeNanoseconds
        VoiceSessionController.appLog(String(format: "intent TalkIntent entered appAgeMs=%.0f",
                                             Double(entered - LatencyTrace.processStart) / 1e6))
        VoiceSessionController.shared.start(trigger: "app_intent", origin: entered)
        return .result()
    }
}

/// Experimental: starts the call in the background, then brings the app forward, so the
/// ~700 ms iOS spends foregrounding the app overlaps the network set-up. The microphone
/// starts once the app is active, because iOS does not allow starting it in the background.
struct FastTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Lobby (fast start)"
    static var description = IntentDescription("Start connecting immediately, then open Wake On.")
    static var openAppWhenRun: Bool = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        let entered = DispatchTime.now().uptimeNanoseconds
        VoiceSessionController.appLog(String(format: "intent FastTalkIntent entered appAgeMs=%.0f state=%d",
                                             Double(entered - LatencyTrace.processStart) / 1e6,
                                             UIApplication.shared.applicationState.rawValue))
        VoiceSessionController.shared.start(trigger: "app_intent_fast", origin: entered)
        if #available(iOS 26.0, *) {
            try await continueInForeground(nil, alwaysConfirm: false)
            VoiceSessionController.shared.noteForegrounded(at: DispatchTime.now().uptimeNanoseconds)
            VoiceSessionController.appLog("intent FastTalkIntent foregrounded")
        }
        return .result()
    }
}

/// A second press ends the call, so one button can toggle it.
struct EndTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "End Lobby call"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceSessionController.appLog("intent EndTalkIntent entered")
        VoiceSessionController.shared.stop(reason: "intent")
        return .result()
    }
}
