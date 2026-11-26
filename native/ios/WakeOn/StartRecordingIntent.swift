import AppIntents
import Foundation

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start recording"
    static var description = IntentDescription("Open Pixie and immediately capture a five-second audio handoff.")
    // Foreground microphone capture also supports the iOS 17 deployment target.
    static var openAppWhenRun: Bool = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        let entered = DispatchTime.now().uptimeNanoseconds
        VoiceSessionController.appLog("intent StartRecordingIntent entered")
        try await WakeController.shared.startDirect(source: "app_intent", entered: entered)
        return .result()
    }
}

struct WakeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // The fast start is the only Talk shortcut: it connects while iOS brings Pixie forward.
        AppShortcut(intent: FastTalkIntent(), phrases: ["Talk to \(.applicationName)", "Fast talk to \(.applicationName)"],
                    shortTitle: "Talk to Pixie", systemImageName: "waveform")
        AppShortcut(intent: EndTalkIntent(), phrases: ["End the \(.applicationName) call"],
                    shortTitle: "End Pixie call", systemImageName: "phone.down.fill")
        AppShortcut(intent: OpenMiniAppIntent(), phrases: ["Open \(\.$app) in \(.applicationName)"],
                    shortTitle: "Open Mini App", systemImageName: "square.grid.2x2")
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start recording", systemImageName: "mic.fill")
    }
}
