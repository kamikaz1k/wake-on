import SwiftUI

/// The everyday screen: talk to Lobby, "Hey Lobby" listening, chat logs, and the few settings
/// that matter. Everything else is under Advanced.
struct SimpleView: View {
    @ObservedObject var wake: WakeController
    @ObservedObject var voice: VoiceSessionController = .shared
    @ObservedObject var logs: ChatLogStore = .shared
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var visualizerPalette = VoicePalette.default.name
    @AppStorage(LiveVoiceConfig.voiceKey) private var voiceName = "marin"
    @AppStorage(ListenerSettings.Key.talkOnWake) private var talkOnWake = false
    @State private var keyDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if voice.phase == .connecting || voice.phase == .live {
                        VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette))
                            .frame(height: 220)
                            .listRowBackground(Color.black)
                            .listRowInsets(EdgeInsets())
                    }
                    switch voice.phase {
                    case .idle:
                        Button {
                            voice.start(trigger: "in_app")
                        } label: {
                            Label("Talk to Lobby", systemImage: "waveform").font(.title3.weight(.semibold))
                        }
                        .disabled(voice.keySource == "missing")
                        .accessibilityIdentifier("simple-talk")
                    case .connecting, .live:
                        Label(voice.status, systemImage: "waveform").foregroundStyle(.secondary)
                        HStack {
                            Button(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill") {
                                voice.toggleMute()
                            }
                            Spacer()
                            Button("End", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                                .accessibilityIdentifier("simple-end")
                        }
                        .buttonStyle(.borderless)
                    case .ending:
                        ProgressView("Ending…")
                    }
                    if let error = voice.error { Text(error).foregroundStyle(.red) }
                } header: { Text("Lobby") } footer: {
                    Text("Or press the Action Button. Say “bye” or press it again to hang up.")
                }

                if voice.keySource == "missing" {
                    Section("OpenAI API key") {
                        SecureField("sk-…", text: $keyDraft).textContentType(.password)
                        Button("Save to Keychain") { voice.saveKey(keyDraft); keyDraft = "" }
                            .disabled(keyDraft.isEmpty)
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { wake.enabled || wake.busy },
                                         set: { $0 ? wake.start() : wake.stop() })) {
                        Label(wake.enabled ? "Listening for “Hey Lobby”" : (wake.busy ? "Starting…" : "Listen for “Hey Lobby”"),
                              systemImage: wake.enabled ? "ear.fill" : "ear")
                    }
                    .disabled(wake.busy)
                    .accessibilityIdentifier("simple-listen")
                    Toggle("Talk after “Hey Lobby”", isOn: $talkOnWake)
                        .accessibilityIdentifier("simple-talk-on-wake")
                } header: { Text("Hands-free") } footer: {
                    Text(talkOnWake ? "Say “Hey Lobby” and your request in one go, even with the phone locked."
                                    : "Turn on “Talk after Hey Lobby” to start a conversation by voice.")
                }

                Section {
                    NavigationLink {
                        ChatLogsView()
                    } label: {
                        LabeledContent {
                            Text("\(logs.logs.count)")
                        } label: {
                            Label("Chat logs", systemImage: "text.bubble")
                        }
                    }
                    .accessibilityIdentifier("simple-chat-logs")
                    Picker(selection: $voiceName) {
                        ForEach(LiveVoiceConfig.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    } label: {
                        Label("Voice", systemImage: "person.wave.2")
                    }
                }
            }
            .navigationTitle("Wake On")
        }
    }
}
