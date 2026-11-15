import SwiftUI

/// When iOS launches the app in the background (fast-start action), build the audio engine
/// right away, ~40 ms before the action itself runs. Nothing records until the call starts.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Battery sessions follow the wake listener and calls from launch on.
        Task { @MainActor in
            BatteryMonitor.shared.activate()
            // The orb in the Dynamic Island while listening.
            #if DEBUG
            if UserDefaults.standard.bool(forKey: AudioExperiments.noLiveActivityKey) {
                VoiceSessionController.appLog("experiment no_live_activity")
                ListeningActivityController.shared.endAll()
            } else {
                ListeningActivityController.shared.activate()
            }
            #else
            ListeningActivityController.shared.activate()
            #endif
            // Screen stays on while charging with Wake On open (a phone on a stand).
            ScreenAwake.shared.activate()
        }
        var prebuild = application.applicationState == .background && OpenAILiveVoiceProvider.useHotAudio
        #if DEBUG
        if UserDefaults.standard.bool(forKey: AudioExperiments.noLaunchPrebuildKey) {
            VoiceSessionController.appLog("experiment no_launch_prebuild")
            prebuild = false
        }
        #endif
        if prebuild {
            HotAudioDevice.shared.mayArm = false
            HotAudioDevice.shared.prebuildAsync { result in
                if case .success(let timing) = result {
                    VoiceSessionController.appLog(String(format: "launch_prebuild sessionMs=%.0f buildMs=%.0f", timing.sessionMs, timing.buildMs))
                }
            }
        }
        return true
    }
}

@main
struct WakeOnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var didLaunchTest = false
    @StateObject private var controller = WakeController.shared
    @Environment(\.scenePhase) private var scenePhase
    init() {
        _ = LatencyTrace.processStart
        ListenerSettings.migrate()
        VoiceSessionController.appLog("app_launch pid=\(ProcessInfo.processInfo.processIdentifier)")
        // Pay WebRTC's one-time setup while the first screen draws.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--no-warm-audio") { OpenAILiveVoiceProvider.warmAudioEngine = false }
        if ProcessInfo.processInfo.arguments.contains("--builtin-audio") { OpenAILiveVoiceProvider.useHotAudio = false }
        #endif
        OpenAILiveVoiceProvider.prewarmMedia()
        WakeShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                // wakeon://talk, wakeon://talk?probe=greeting|search, wakeon://end
                .onOpenURL { url in
                    VoiceSessionController.appLog("open_url \(url.host ?? "")")
                    let entered = DispatchTime.now().uptimeNanoseconds
                    switch url.host {
                    case "talk":
                        let probe = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first { $0.name == "probe" }?.value.flatMap(VoiceSessionController.Probe.init)
                        VoiceSessionController.shared.start(trigger: "url", origin: entered, probe: probe)
                    case "end":
                        VoiceSessionController.shared.stop(reason: "url")
                    default:
                        break
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    VoiceSessionController.appLog("scene \(phase)")
                    // Open the TLS connection early so a call skips that round trip.
                    if phase == .active {
                        OpenAILiveVoiceProvider.prewarm()
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--no-prepare") { return }
                        #endif
                        VoiceSessionController.shared.prepareNext()
                    }
                }
                .onAppear {
                    #if DEBUG
                    guard !didLaunchTest else { return }
                    didLaunchTest = true
                    let args = ProcessInfo.processInfo.arguments
                    // --voice <name>: choose Lobby's voice (as the Voice setting does).
                    if let index = args.firstIndex(of: "--voice"), index + 1 < args.count {
                        UserDefaults.standard.set(args[index + 1], forKey: LiveVoiceConfig.voiceKey)
                    }
                    if let index = args.firstIndex(of: "--media"), index + 1 < args.count {
                        // --media pause|play|next|previous: send it without a call (MediaControl).
                        let delay = args.firstIndex(of: "--media-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
                        // With the listener on, the app keeps running in the background, so the
                        // command can be tried with the phone locked.
                        if args.contains("--autostart") { controller.start() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if let command = MediaControl.Command(rawValue: args[index + 1]) { MediaControl.run(command) }
                        }
                    } else if let index = args.firstIndex(of: "--demo-call"), index + 1 < args.count {
                        // Plays a saved capture into the live call screen, without connecting.
                        VoiceSessionController.shared.demoCall(capture: URL(fileURLWithPath: args[index + 1]))
                    } else if let index = args.firstIndex(of: "--talk") {
                        let next = args.indices.contains(index + 1) ? args[index + 1] : ""
                        // --resume: carry on the newest saved chat (resumed-chat test).
                        let resuming = args.contains("--resume") ? ChatLogStore.shared.logs.first : nil
                        VoiceSessionController.shared.start(trigger: "launch_argument",
                                                            probe: VoiceSessionController.Probe(rawValue: next),
                                                            resuming: resuming)
                        // --pause-after N: press Pause N seconds in (the browser pause test).
                        if let at = args.firstIndex(of: "--pause-after"), at + 1 < args.count, let seconds = Double(args[at + 1]) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { VoiceSessionController.shared.pause() }
                        }
                    } else if args.contains("--intent-test") {
                        Task {
                            do {
                                if args.contains("--reuse-mic") {
                                    controller.start()
                                    for _ in 0..<250 {
                                        if controller.status == "Listening for Hey Lobby" { break }
                                        try await Task.sleep(nanoseconds: 20_000_000)
                                    }
                                    guard controller.enabled else { throw WakeError.message("Wake microphone did not initialize.") }
                                }
                                _ = try await StartRecordingIntent().perform()
                                if args.contains("--repeat-intent") { _ = try await StartRecordingIntent().perform() }
                            }
                            catch { controller.error = error.localizedDescription }
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("--autostart") {
                        controller.start()
                        // --talk-after N: start a voice call while the listener runs (hand-off test).
                        if let index = args.firstIndex(of: "--talk-after"), index + 1 < args.count, let seconds = Double(args[index + 1]) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                                VoiceSessionController.shared.start(trigger: "talk_after", probe: .greeting)
                            }
                        }
                    }
                    #endif
                }
        }
    }
}
