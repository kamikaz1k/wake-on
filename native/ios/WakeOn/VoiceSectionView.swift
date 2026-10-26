import SwiftUI

/// Call controls, the live transcript, and the latency numbers for the current call.
struct VoiceSectionView: View {
    @ObservedObject var voice: VoiceSessionController
    @State private var keyDraft = ""
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var visualizerPalette = VoicePalette.default.name

    var body: some View {
        Section {
            if voice.phase == .connecting || voice.phase == .live {
                VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette))
                    .frame(height: 260)
                    .listRowBackground(Color.black)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("voice-visualizer")
            }
            Label(voice.status, systemImage: icon).font(.headline)
                .accessibilityIdentifier("voice-status")
            switch voice.phase {
            case .idle:
                Button("Talk to Lobby", systemImage: "waveform") {
                    voice.start(trigger: "in_app")
                }
                .disabled(voice.keySource == "missing")
                .accessibilityIdentifier("voice-start")
            case .connecting, .live:
                HStack {
                    Button(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill") {
                        voice.toggleMute()
                    }
                    Spacer()
                    Button("End", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                        .accessibilityIdentifier("voice-end")
                }
                .buttonStyle(.borderless)
            case .ending:
                ProgressView("Ending…")
            }
            if let error = voice.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("voice-error")
            }
            NavigationLink {
                VoiceVisualizerGallery()
            } label: {
                LabeledContent("Visualizer", value: visualizerStyle.title)
            }
            .accessibilityIdentifier("visualizer-gallery")
        } header: { Text("Voice assistant") } footer: {
            Text("Assign Talk to Lobby to the Action Button: Settings › Action Button › Shortcut › Wake On.")
        }

        if voice.keySource == "missing" {
            Section("OpenAI API key") {
                SecureField("sk-…", text: $keyDraft).textContentType(.password)
                Button("Save to Keychain") { voice.saveKey(keyDraft); keyDraft = "" }
                    .disabled(keyDraft.isEmpty)
            }
        }

        if !voice.transcript.isEmpty {
            Section("Transcript") {
                ForEach(voice.transcript) { line in
                    Text("\(Text(line.speaker).bold()): \(line.text)")
                }
            }
        }

        if !voice.timeline.isEmpty || voice.lastResponseMs != nil || voice.listeningMs != nil {
            Section("Voice latency") {
                if let listening = voice.listeningMs {
                    LabeledContent("Trigger → listening", value: Self.ms(listening))
                        .accessibilityIdentifier("voice-listening")
                }
                if let reaching = voice.reachingMs {
                    LabeledContent("Trigger → audio reaching OpenAI", value: Self.ms(reaching))
                }
                if let last = voice.lastResponseMs {
                    LabeledContent("Last reply", value: Self.ms(last))
                        .accessibilityIdentifier("voice-last-reply")
                }
                if let median = voice.medianResponseMs, voice.responseHistory.count > 1 {
                    LabeledContent("Median reply (\(voice.responseHistory.count))", value: Self.ms(median))
                }
                if let rtt = voice.roundTripMs { LabeledContent("Network round trip", value: Self.ms(rtt)) }
                if let jitter = voice.jitterBufferMs { LabeledContent("Jitter buffer", value: Self.ms(jitter)) }
                if let usage = voice.usageSeconds { LabeledContent("Billed audio", value: String(format: "%.0f s", usage)) }
                DisclosureGroup("Setup timeline") {
                    ForEach(voice.timeline) { row in
                        LabeledContent(row.name.replacingOccurrences(of: "_", with: " "), value: Self.ms(row.ms))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private var icon: String {
        switch voice.phase {
        case .idle: "waveform.slash"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .live: "waveform"
        case .ending: "phone.down"
        }
    }

    private static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}
