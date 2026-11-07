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
    @AppStorage(LiveVoiceConfig.nameKey) private var assistantName = LiveVoiceConfig.defaultName
    @State private var keyDraft = ""

    var body: some View {
        NavigationStack {
            List {
                ModePicker.row
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
                            Text("Start chat")
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
                } footer: {
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
                    // One switch: background listening that starts a conversation on "Hey Lobby".
                    // (Advanced keeps the listener's separate options, including notify-only.)
                    Toggle(isOn: Binding(get: { (wake.enabled || wake.busy) && talkOnWake },
                                         set: { on in
                                             if on {
                                                 talkOnWake = true
                                                 if !wake.enabled && !wake.busy { wake.start() }
                                             } else {
                                                 wake.stop()
                                             }
                                         })) {
                        Text(wake.busy ? "Starting…" : "Enable background listening")
                    }
                    .disabled(wake.busy)
                    .accessibilityIdentifier("simple-hands-free")
                } header: { Text("Hands-free") } footer: {
                    Text("Listens for “Hey Lobby”, even with the phone locked. Say it and your request in one go. When off, start a conversation with the button above or the Action Button.")
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
                    LabeledContent("Assistant name") {
                        TextField(LiveVoiceConfig.defaultName, text: $assistantName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("simple-assistant-name")
                    }
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
        }
    }
}
