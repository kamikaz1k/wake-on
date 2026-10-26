import SwiftUI

// A functional native test surface: listening controls first, then the actual captured handoff.
struct ContentView: View {
    @ObservedObject var controller: WakeController
    var body: some View {
        NavigationStack {
            List {
                VoiceSectionView(voice: VoiceSessionController.shared)
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
        }
    }
}
