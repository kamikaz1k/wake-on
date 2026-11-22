import SwiftUI

/// Call controls, the live transcript, and the latency numbers for the current call.
/// `part` splits it so other sections can sit between the controls and the call details.
struct VoiceSectionView: View {
    enum Part { case controls, details }
    @ObservedObject var voice: VoiceSessionController
    var part: Part = .controls
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var visualizerPalette = VoicePalette.default.name
    @AppStorage(VoiceSessionController.idleSecondsKey) private var idleSeconds = 10.0
    @AppStorage(LiveVoiceConfig.voiceKey) private var voiceName = "marin"

    var body: some View {
        switch part {
        case .controls: controls
        case .details: details
        }
    }

    @ViewBuilder private var controls: some View {
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
            Picker("Voice", selection: $voiceName) {
                ForEach(LiveVoiceConfig.voices, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .accessibilityIdentifier("voice-name")
            NavigationLink {
                VoiceVisualizerGallery()
            } label: {
                LabeledContent("Visualizer", value: visualizerStyle.title)
            }
            .accessibilityIdentifier("visualizer-gallery")
            Picker("Check in after silence", selection: $idleSeconds) {
                Text("Off").tag(0.0)
                ForEach([5.0, 10, 15, 20, 30], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .accessibilityIdentifier("voice-idle-seconds")
        } header: { Text("Voice assistant") } footer: {
            Text("Assign Talk to Lobby to the Action Button: Settings › Action Button › Shortcut › Wake On. "
                 + "Press it again to hang up. Lobby asks if there is anything else after an answer, or after "
                 + "the silence time; the call ends 4 s after that question with no answer, or 2 s after Lobby says bye.")
        }

        Section { APIKeyLink(voice: voice) }

    }

    @ViewBuilder private var details: some View {
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

/// A settings row that opens the invite code / OpenAI key page, showing whether one is set.
struct APIKeyLink: View {
    @ObservedObject var voice: VoiceSessionController
    @AppStorage(LobbyServer.needsNewCodeKey) private var needsNewCode = false

    var body: some View {
        NavigationLink {
            APIKeyView(voice: voice)
        } label: {
            LabeledContent("Invite Code or Key", value: value)
        }
        .accessibilityIdentifier("api-key-link")
    }

    private var value: String {
        if voice.keySource == "missing" { return "Not set" }
        return needsNewCode ? "Needs a new code" : "Saved"
    }
}

/// An invite code (calls go through the Lobby server) or an OpenAI API key (calls go straight
/// to OpenAI): enter or replace it (saved to the Keychain), or remove it.
struct APIKeyView: View {
    @ObservedObject var voice: VoiceSessionController
    @State private var keyDraft = ""
    @AppStorage(LobbyServer.needsNewCodeKey) private var needsNewCode = false

    var body: some View {
        Form {
            Section {
                SecureField(voice.keySource == "missing" ? "Invite code or sk-…" : "New code or key", text: $keyDraft)
                    .textContentType(.password)
                    .accessibilityIdentifier("api-key-field")
                Button("Save to Keychain") { voice.saveKey(keyDraft); keyDraft = "" }
                    .disabled(keyDraft.isEmpty)
            } footer: {
                Text(status)
            }
            if voice.keySource == "keychain" {
                Section {
                    Button("Remove", role: .destructive) { voice.forgetKey() }
                }
            }
        }
        .navigationTitle("Invite Code or Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var status: String {
        switch voice.keySource {
        case "keychain" where needsNewCode:
            "The saved invite code doesn't work anymore. Ask for a new one and enter it above."
        case "keychain": "Saved in this iPhone's Keychain. Lobby needs it to talk."
        case "environment": "Using the key from the launch environment (debug builds)."
        default: "Lobby needs an invite code, or your own OpenAI API key, to talk. It's kept in this iPhone's Keychain."
        }
    }
}
