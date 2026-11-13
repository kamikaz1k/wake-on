import SwiftUI

/// Two tabs in the standard tab bar (Liquid Glass on iOS 26): Simple (everyday controls) and
/// Advanced (the full test surface).
struct ContentView: View {
    enum Mode: String { case advanced, simple }
    @ObservedObject var controller: WakeController
    @AppStorage("ui.tab") private var mode: Mode = .simple
    @ObservedObject private var browser = BrowserSession.shared
    @State private var browserDetent: PresentationDetent = .large
    /// Debug screenshots of the visualizer gallery (Advanced) open that tab.
    static let galleryRequested = ProcessInfo.processInfo.arguments.contains("-visualizer-gallery")

    var body: some View {
        TabView(selection: Binding(get: { Self.galleryRequested ? .advanced : mode }, set: { mode = $0 })) {
            AdvancedView(controller: controller)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Mode.advanced)
            SimpleView(wake: controller)
                .tabItem { Label("Simple", systemImage: "waveform") }
                .tag(Mode.simple)
        }
        // Lobby's browser, or yours from the Simple page. At half height the call stays usable.
        .sheet(isPresented: $browser.isOpen) {
            BrowserSheet(browser: browser)
                .presentationDetents([.medium, .large], selection: $browserDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        #if DEBUG
        // `-browser <address or words>`, then `-browser-step <action> <text>` (repeatable):
        // Lobby's browser steps without a call, results in the voice log.
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
                    Text("Say “Hey Lobby”, then keep speaking. Audio stays on this iPhone.")
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
            }
            .navigationTitle("Wake On")
            #if DEBUG
            .navigationDestination(isPresented: $openGallery) {
                VoiceVisualizerGallery(autoplay: ProcessInfo.processInfo.arguments.contains("-visualizer-autoplay"))
            }
            #endif
        }
    }
}
