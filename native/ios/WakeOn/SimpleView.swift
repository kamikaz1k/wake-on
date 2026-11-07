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
    @AppStorage(ScreenAwake.key) private var awakeWhileCharging = true
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
                            Text("Talk to Lobby")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .disabled(voice.keySource == "missing")
                        .accessibilityIdentifier("simple-talk")
                    case .connecting, .live:
                        Text(voice.status).foregroundStyle(.secondary)
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
                        Text(wake.enabled ? "Listening for “Hey Lobby”" : (wake.busy ? "Starting…" : "Listen for “Hey Lobby”"))
                    }
                    .disabled(wake.busy)
                    .accessibilityIdentifier("simple-listen")
                    Toggle("Start a conversation on “Hey Lobby”", isOn: $talkOnWake)
                        .accessibilityIdentifier("simple-talk-on-wake")
                } header: { Text("Hands-free") } footer: {
                    Text(talkOnWake ? "Say “Hey Lobby” and your request in one go, even with the phone locked."
                                    : "Hearing “Hey Lobby” only shows a notification; no conversation starts.")
                }

                Section {
                    NavigationLink {
                        ChatLogsView()
                    } label: {
                        LabeledContent {
                            Text("\(logs.logs.count)")
                        } label: {
                            Text("Chat logs")
                        }
                    }
                    .accessibilityIdentifier("simple-chat-logs")
                    Picker(selection: $voiceName) {
                        ForEach(LiveVoiceConfig.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    } label: {
                        Text("Voice")
                    }
                    Toggle("Keep screen on while charging", isOn: $awakeWhileCharging)
                    .accessibilityIdentifier("simple-awake-charging")
                } footer: {
                    Text("While charging, the screen stays on as long as Wake On is open, like on a stand.")
                }
            }
            .navigationTitle("Wake On")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ModePicker() } }
        }
    }
}
