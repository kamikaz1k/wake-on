import SwiftUI

/// When iOS launches the app in the background (fast-start action), build the audio engine
/// right away, ~40 ms before the action itself runs. Nothing records until the call starts.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if application.applicationState == .background, OpenAILiveVoiceProvider.useHotAudio {
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
                    if let index = args.firstIndex(of: "--talk") {
                        let next = args.indices.contains(index + 1) ? args[index + 1] : ""
                        VoiceSessionController.shared.start(trigger: "launch_argument",
                                                            probe: VoiceSessionController.Probe(rawValue: next))
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
                    } else if ProcessInfo.processInfo.arguments.contains("--autostart") { controller.start() }
                    #endif
                }
        }
    }
}
