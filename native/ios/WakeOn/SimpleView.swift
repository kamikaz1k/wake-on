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
    @AppStorage(BrowserTool.enabledKey) private var browserEnabled = true
    /// Screenshot/debug launch argument: open straight to the chat logs.
    @State private var openLogs = ProcessInfo.processInfo.arguments.contains("-chat-logs")
    /// Screenshot launch argument: open straight to the browser's sign-in sites.
    @State private var openSignIns = ProcessInfo.processInfo.arguments.contains("-sign-ins")
    /// Opens Invite Code or Key from the set-up button shown while neither is saved
    /// (screenshot launch argument: -key-setup).
    @State private var openKeySetup = ProcessInfo.processInfo.arguments.contains("-key-setup")

    /// Emptied when a call starts, so a call resumed from a saved chat shows the call screen.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if #available(iOS 18.0, *), voice.phase != .idle, let chat = voice.liveChat {
                    LiveCallScreen(voice: voice, transcript: chat.transcript,
                                   visualizer: VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette)))
                } else {
                    list
                }
            }
            .navigationTitle("Wake On")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $openLogs) { ChatLogsView() }
            .navigationDestination(isPresented: $openSignIns) { BrowserSignInsView() }
            .navigationDestination(isPresented: $openKeySetup) { APIKeyView(voice: voice) }
            .onChange(of: voice.phase) { old, new in
                if old == .idle, new != .idle {
                    path = NavigationPath()
                    openLogs = false
                    openSignIns = false
                    openKeySetup = false
                }
            }
        }
    }

    private var list: some View {
            List {
                Section {
                    if voice.phase == .connecting || voice.phase == .live {
                        VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette))
                            .frame(height: 220)
                            .listRowBackground(Color.black)
                            .listRowInsets(EdgeInsets())
                    }
                    switch voice.phase {
                    case .idle where voice.keySource == "missing":
                        // Nothing to call with yet: the main button sets that up instead.
                        Button {
                            openKeySetup = true
                        } label: {
                            Text("Add Invite Code or Key")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("simple-add-key")
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
                    if let error = voice.error {
                        // No card: it shares a section with the clear button row, so a card would
                        // get square top corners. Plain red text under the button instead.
                        Text(error)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("simple-error")
                    }
                } footer: {
                    if voice.keySource == "missing" {
                        Text("To talk to Lobby, enter an invite code from a friend, or your own OpenAI API key.")
                    } else {
                        Text("Or press the Action Button. Say “bye” or press it again to hang up.")
                    }
                }


                Section {
                    NavigationLink {
                        ChatLogsView()
                    } label: {
                        LabeledContent {
                            Text("\(logs.logs.count)")
                        } label: {
                            Text("Chat history")
                        }
                    }
                    .accessibilityIdentifier("simple-chat-logs")
                    Button("Open Browser") { BrowserSession.shared.show() }
                        .accessibilityIdentifier("simple-browser")
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
                    Toggle("Lobby can use the browser", isOn: $browserEnabled)
                        .accessibilityIdentifier("simple-browser-enabled")
                    BrowserSignInsLink()
                    ObsidianVaultRow()
                    Toggle("Keep screen on while charging", isOn: $awakeWhileCharging)
                        .accessibilityIdentifier("simple-awake-charging")
                    Picker(selection: $voiceName) {
                        ForEach(LiveVoiceConfig.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    } label: {
                        Text("Voice")
                    }
                    NavigationLink {
                        VoiceVisualizerGallery()
                    } label: {
                        LabeledContent("Visualizer", value: visualizerStyle.title)
                    }
                    .accessibilityIdentifier("simple-visualizer")
                    APIKeyLink(voice: voice)
                } header: { Text("Settings") } footer: {
                    Text("Background listening hears “Hey Lobby”, even with the phone locked: say it and your request in one go. With the browser on, Lobby can open, search and read websites; it keeps you signed in only to the sites you choose. While charging, the screen stays on as long as Wake On is open.")
                }
            }
    }
}

/// During a call: the orb, the conversation in Lobby's chat view as it happens (the same view
/// and rows as the chat log afterwards), and the call controls.
@available(iOS 18.0, *)
private struct LiveCallScreen: View {
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var transcript: ChatTranscript
    let visualizer: VoiceVisualizer

    var body: some View {
        VStack(spacing: 0) {
            visualizer
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)
            ChatTranscriptView(items: transcript.items, call: transcript.call, showsHeader: false)
                .accessibilityIdentifier("live-chat")
            ChatLengthWarning(tokens: voice.threadTokens)
            controls
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let error = voice.error { Text(error).foregroundStyle(.red).font(.footnote) }
            HStack {
                Button(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill") {
                    voice.toggleMute()
                }
                .disabled(voice.phase == .ending)
                Spacer()
                Text(voice.phase == .ending ? "Ending…" : voice.status)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("End", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                    .disabled(voice.phase == .ending)
                    .accessibilityIdentifier("simple-end")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }
}
