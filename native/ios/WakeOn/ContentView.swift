import SwiftUI

/// Simple (everyday controls) or Advanced (the full test surface), switched with a compact
/// segmented control in the navigation bar. A tab bar reserved icon space even with text only.
struct ContentView: View {
    enum Mode: String { case advanced, simple }
    @ObservedObject var controller: WakeController
    @AppStorage(ModePicker.key) private var mode: Mode = .simple
    /// Debug screenshots of the visualizer gallery (Advanced) open that mode.
    static let galleryRequested = ProcessInfo.processInfo.arguments.contains("-visualizer-gallery")

    var body: some View {
        if mode == .advanced || Self.galleryRequested {
            AdvancedView(controller: controller)
        } else {
            SimpleView(wake: controller)
        }
    }
}

/// "Advanced | Simple", shown at the top right of both screens.
struct ModePicker: View {
    static let key = "ui.tab"
    @AppStorage(key) private var mode: ContentView.Mode = .simple
    var body: some View {
        Picker("Mode", selection: $mode) {
            Text("Advanced").tag(ContentView.Mode.advanced)
            Text("Simple").tag(ContentView.Mode.simple)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("mode-picker")
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ModePicker() } }
            #if DEBUG
            .navigationDestination(isPresented: $openGallery) {
                VoiceVisualizerGallery(autoplay: ProcessInfo.processInfo.arguments.contains("-visualizer-autoplay"))
            }
            #endif
        }
    }
}
