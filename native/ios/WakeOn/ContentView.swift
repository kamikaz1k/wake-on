import SwiftUI

/// First run: onboarding. After that: the chat-first home screen, with settings in a sheet and
/// the old Advanced page under Settings › Developer (debug builds).
struct ContentView: View {
    @ObservedObject var controller: WakeController
    @AppStorage(Onboarding.doneKey) private var onboardingDone = false
    /// `-onboarding` shows setup even after it was done (screenshots, trying it again).
    @State private var forceOnboarding = ProcessInfo.processInfo.arguments.contains("-onboarding")
    @ObservedObject private var browser = BrowserSession.shared
    @ObservedObject private var voice = VoiceSessionController.shared
    /// Debug screenshots of the visualizer gallery (Advanced) open that tab.
    static let galleryRequested = ProcessInfo.processInfo.arguments.contains("-visualizer-gallery")
    /// Screenshot and test launches open the main screen directly; `-onboarding` forces setup.
    static var skipsOnboarding: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-onboarding") { return false }
        return args.contains("-no-onboarding") || args.contains("-chat-logs") || args.contains("-sign-ins")
            || args.contains("-key-setup") || args.contains("-settings")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some View {
        Group {
            if Self.galleryRequested {
                AdvancedView(controller: controller)
            } else if (onboardingDone && !forceOnboarding) || Self.skipsOnboarding {
                HomeView(wake: controller)
            } else {
                OnboardingView(wake: controller) {
                    onboardingDone = true
                    forceOnboarding = false
                }
            }
        }
        // Pixie's browser, or yours from the Simple page: full screen so its top bar can take
        // the page's colour behind the status bar, as Safari and Chrome do.
        .fullScreenCover(isPresented: $browser.isOpen) {
            BrowserSheet(browser: browser)
        }
        // Before the first call: permission to send the user's voice to OpenAI.
        .sheet(isPresented: Binding(get: { voice.consentNeeded },
                                    set: { if !$0, voice.consentNeeded { voice.answerConsent(false) } })) {
            AIConsentView(agree: { voice.answerConsent(true) }, decline: { voice.answerConsent(false) })
        }
        #if DEBUG
        // Screenshot launch argument: show the permission sheet.
        .task { if ProcessInfo.processInfo.arguments.contains("-consent-sheet") { voice.requestConsent {} } }
        #endif
        #if DEBUG
        // `-browser <address or words>`, then `-browser-step <action> <text>` (repeatable):
        // Pixie's browser steps without a call, results in the voice log.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-browser"), index + 1 < args.count else { return }
            BrowserSession.shared.show(args[index + 1])
            for (i, arg) in args.enumerated() where arg == "-browser-step" && i + 2 < args.count {
                try? await Task.sleep(for: .seconds(2))
                let result = await BrowserSession.shared.perform(action: args[i + 1], text: args[i + 2])
                VoiceSessionController.appLog("browser_step \(args[i + 1]) \(args[i + 2]) → \(result.replacingOccurrences(of: "\n", with: " | "))")
            }
        }
        #endif
    }
}

// A functional native test surface: call controls, then the wake listener, then call details
// and the captured handoff.
struct AdvancedView: View {
    @ObservedObject var controller: WakeController
    #if DEBUG
    /// Launch with `-visualizer-gallery` (add `-visualizer-autoplay` to start the sample) for screenshots.
    @State private var openGallery = ProcessInfo.processInfo.arguments.contains("-visualizer-gallery")
    #endif
    var body: some View {
        NavigationStack {
            List {
                VoiceSectionView(voice: VoiceSessionController.shared)
                Section {
                    Label(controller.status, systemImage: controller.enabled ? "mic.fill" : "mic.slash")
                        .font(.headline)
                        .accessibilityIdentifier("wake-status")
                    Text("Say “\(Agent.wakePhrase)”, then keep speaking. Audio stays on this iPhone.")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        BatteryView(monitor: BatteryMonitor.shared, wake: controller)
                    } label: {
                        Label("Battery use", systemImage: "battery.75percent")
                    }
                    .accessibilityIdentifier("battery-view")
                    if controller.enabled {
                        Button("Disable listening", role: .destructive) { controller.stop() }
                    } else {
                        Button(controller.busy ? "Preparing…" : "Enable listening") { controller.start() }
                            .disabled(controller.busy)
                    }
                } header: { Text("Wake listener") } footer: {
                    Text("Enable listening before leaving the app or locking the screen. iOS does not let a wake word open the screen automatically.")
                }
                ListenerOptionsView(controller: controller)
                VoiceSectionView(voice: VoiceSessionController.shared, part: .details)
                Section("Record immediately") {
                    Button("Record now", systemImage: "record.circle") {
                        Task {
                            do { try await controller.startDirect(source: "in_app") }
                            catch { controller.error = error.localizedDescription }
                        }
                    }.accessibilityIdentifier("record-now")
                    Text("Captures five seconds without a wake word. Assign Start recording to your Action button in Settings → Action Button → Shortcut.")
                        .foregroundStyle(.secondary)
                }

                if let capture = controller.handoff {
                    Section("Audio handoff") {
                        Label(controller.wakeLocation, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Phrase", value: capture.phrase.replacingOccurrences(of: "_", with: " "))
                        LabeledContent("Captured audio", value: String(format: "%.2f seconds", capture.duration))
                        LabeledContent("Format", value: "16 kHz · mono")
                        if capture.complete {
                            Button(controller.isPlaying ? "Stop playback" : "Play captured audio", systemImage: controller.isPlaying ? "stop.fill" : "play.fill") {
                                controller.playHandoff()
                            }
                            Button("Listen for another wake") { controller.rearm() }
                        } else {
                            ProgressView(capture.phrase == "DIRECT_RECORDING" ? "Recording five seconds…" : "Keeping the next 3 seconds…")
                        }
                    }
                }
                if let error = controller.error {
                    Section("Needs attention") { Text(error).foregroundStyle(.red) }
                }
                Section("Latency diagnostics") {
                    Text(controller.latencySummary.isEmpty ? "Every capture records timing milestones locally." : controller.latencySummary)
                    ShareLink("Export latency traces", item: LatencyTrace.fileURL)
                }
                Section("Background use") {
                    Text(controller.notificationNote.isEmpty ? "A wake notification lets you return to the captured audio." : controller.notificationNote)
                    Text("After a wake, detection pauses until you rearm it. Calls and input changes stop this prototype; enable listening again afterward.")
                        .foregroundStyle(.secondary)
                }
                #if DEBUG
                AudioExperimentsSection()
                #endif
            }
            .navigationTitle("Pixie")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .navigationDestination(isPresented: $openGallery) {
                VoiceVisualizerGallery(autoplay: ProcessInfo.processInfo.arguments.contains("-visualizer-autoplay"))
            }
            #endif
        }
    }
}

#if DEBUG
/// Switches that leave out one launch-time audio piece, to find what interrupts the listener.
/// See `.claude/skills/ios-audio/regression.md`.
enum AudioExperiments {
    static let noLiveActivityKey = "debug.noLiveActivity"
    static let noLaunchPrebuildKey = "debug.noLaunchPrebuild"
}

private struct AudioExperimentsSection: View {
    @AppStorage(AudioExperiments.noLiveActivityKey) private var noLiveActivity = false
    @AppStorage(AudioExperiments.noLaunchPrebuildKey) private var noLaunchPrebuild = false

    var body: some View {
        Section {
            Toggle("No Dynamic Island orb", isOn: $noLiveActivity)
            Toggle("No call audio prepared at launch", isOn: $noLaunchPrebuild)
        } header: {
            Text("Audio experiments")
        } footer: {
            Text("Debug builds only. Takes effect the next time Pixie launches: swipe it away, then open it from its icon.")
        }
    }
}
#endif
