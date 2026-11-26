import SwiftUI

/// The main screen: Pixie's chat. The latest chat (or the live call) fills the screen, with a
/// talk button at the bottom; history and settings sit in the toolbar.
struct HomeView: View {
    @ObservedObject var wake: WakeController
    @ObservedObject var voice: VoiceSessionController = .shared
    @ObservedObject var logs: ChatLogStore = .shared
    @ObservedObject private var invite = InviteLink.shared
    @ObservedObject private var network = NetworkPath.shared
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var visualizerPalette = VoicePalette.default.name
    /// Screenshot/debug launch argument: open straight to the chat logs.
    @State private var openLogs = ProcessInfo.processInfo.arguments.contains("-chat-logs")
    /// Screenshot launch argument: open straight to the browser's sign-in sites.
    @State private var openSignIns = ProcessInfo.processInfo.arguments.contains("-sign-ins")
    /// Opens Invite Code or Key from the set-up button shown while neither is saved, or from an
    /// invite link (screenshot launch argument: -key-setup).
    @State private var openKeySetup = ProcessInfo.processInfo.arguments.contains("-key-setup")
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-settings")
    /// Screenshot launch argument: open straight to My Apps.
    @State private var openApps = ProcessInfo.processInfo.arguments.contains("-mini-apps")
    /// The idle orb (the start button) and the call screen's orb are one view to SwiftUI, so
    /// starting a chat moves and grows the orb into place. Only the way up is animated: the phone
    /// hung (watchdog kill) right as a call ended and the orb animated back down, 2026-11-24.
    @Namespace private var orbSpace

    private var visualizer: VoiceVisualizer {
        VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette))
    }

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 18.0, *), voice.phase != .idle, let chat = voice.liveChat {
                    LiveCallScreen(voice: voice, transcript: chat.transcript, visualizer: visualizer,
                                   orbSpace: orbSpace)
                } else {
                    idle
                }
            }
            .navigationTitle("Pixie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if voice.phase == .idle {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Chat History", systemImage: "clock.arrow.circlepath") { openLogs = true }
                            .accessibilityIdentifier("home-history")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("My Apps", systemImage: "square.grid.2x2") { openApps = true }
                            .accessibilityIdentifier("home-apps")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Open Browser", systemImage: "globe") { BrowserSession.shared.show() }
                            .accessibilityIdentifier("home-browser")
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                            .accessibilityIdentifier("home-settings")
                    }
                }
            }
            .navigationDestination(isPresented: $openLogs) { ChatLogsView() }
            .navigationDestination(isPresented: $openApps) { MiniAppsView() }
            .navigationDestination(isPresented: $openSignIns) { BrowserSignInsView() }
            .navigationDestination(isPresented: $openKeySetup) {
                APIKeyView(voice: voice, prefill: invite.code, onValid: { invite.code = nil; openKeySetup = false })
            }
            .sheet(isPresented: $showSettings) { SettingsView(wake: wake) }
            .onChange(of: voice.phase) { old, new in
                if old == .idle, new != .idle {
                    openLogs = false
                    openApps = false
                    openSignIns = false
                    openKeySetup = false
                    showSettings = false
                }
            }
            .onChange(of: invite.code) { _, code in if code != nil { openKeySetup = true } }
            #if DEBUG
            .task {
                // `-orb-tap-demo`: press the orb 2 s after launch, for recording the transition.
                guard ProcessInfo.processInfo.arguments.contains("-orb-tap-demo") else { return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(Self.orbFlight) { voice.start(trigger: "in_app") }
            }
            #endif
        }
    }

    /// Between calls: the latest chat, or suggestions when there's none yet, and the talk bar.
    @ViewBuilder private var idle: some View {
        Group {
            if #available(iOS 18.0, *), voice.keySource != "missing", let last = logs.logs.first {
                ChatLogTranscript(log: last, capture: logs.captureURL(for: last.id)).id(last.id)
            } else {
                suggestions
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { talkBar }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(voice.keySource == "missing" ? "Set up to talk to \(Agent.name)" : "Ask \(Agent.name) anything")
                    .font(.title2.bold())
                Text(voice.keySource == "missing"
                     ? "Enter an invite code from a friend, or your own OpenAI API key."
                     : "Tap a question, or start a chat and just talk.")
                    .foregroundStyle(.secondary)
                if voice.keySource != "missing" {
                    ForEach(Onboarding.prompts, id: \.label) { prompt in
                        Button { voice.start(trigger: "in_app", prompt: prompt.text) } label: {
                            Label(prompt.label, systemImage: prompt.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var talkBar: some View {
        VStack(spacing: 8) {
            if let error = voice.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("simple-error")
            }
            switch voice.phase {
            case .idle where voice.keySource == "missing":
                // Nothing to call with yet: the main button sets that up instead.
                bigButton("Add Invite Code or Key", id: "simple-add-key") { openKeySetup = true }
            case .idle:
                if let note = voice.voiceNote {
                    VoiceNoteCard(note: note, online: network.isUp,
                                  resume: { voice.resumeVoiceNote() }, discard: { voice.discardVoiceNote() })
                } else if !network.isUp {
                    NetworkStatusBadge()
                }
                orbButton
                    .disabled(!network.isUp)
                    .grayscale(network.isUp ? 0 : 1)
                    .opacity(network.isUp ? 1 : 0.5)
                Text(network.isUp ? "Tap the orb, or press the Action Button.\nSay “bye” to hang up."
                                  : "Pixie needs an internet connection.")
                    .multilineTextAlignment(.center)
                    .font(.footnote).foregroundStyle(.secondary)
            case .connecting, .live, .ending:
                // iOS 17 has no live chat view: plain call controls.
                HStack {
                    Text(voice.status).foregroundStyle(.secondary)
                    Spacer()
                    Button("End", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                        .accessibilityIdentifier("simple-end")
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        // The orb sits on the page's own background, not in a grey bar.
        .background(Color(.systemBackground))
    }

    /// The start button: the call's orb at rest. Tapping it starts a chat, and the orb grows into
    /// the top of the call screen (iOS 18 and later; iOS 17 has no live chat view).
    private var orbButton: some View {
        Button { withAnimation(Self.orbFlight) { voice.start(trigger: "in_app") } } label: {
            visualizer
                .matchedGeometryEffect(id: "orb", in: orbSpace)
                .frame(width: 150, height: 130)
                .contentShape(Circle().inset(by: 25))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start chat")
        .accessibilityIdentifier("simple-talk")
    }

    static let orbFlight = Animation.spring(duration: 0.55, bounce: 0.2)

    private func bigButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier(id)
    }
}

/// Everything adjustable, in a sheet from the main screen's gear.
struct SettingsView: View {
    @ObservedObject var wake: WakeController
    @ObservedObject var voice: VoiceSessionController = .shared
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(LiveVoiceConfig.voiceKey) private var voiceName = "marin"
    @AppStorage(ListenerSettings.Key.talkOnWake) private var talkOnWake = false
    @AppStorage(ScreenAwake.key) private var awakeWhileCharging = true
    @AppStorage(BrowserTool.enabledKey) private var browserEnabled = true
    @AppStorage(AIConsent.key) private var openAIConsent = false
    @AppStorage(Onboarding.doneKey) private var onboardingDone = true
    @Environment(\.dismiss) private var dismiss
    @State private var showDeveloper = false
    @ObservedObject private var memory: MemoryStore = .shared
    /// "-memory" opens Settings › Memory, for screenshots.
    @State private var openMemory = ProcessInfo.processInfo.arguments.contains("-memory")

    var body: some View {
        NavigationStack {
            List {
                Section {
                    APIKeyLink(voice: voice)
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
                    NavigationLink {
                        MemoryView()
                    } label: {
                        LabeledContent("Memory", value: "\(memory.memory.notes.count)")
                    }
                    .accessibilityIdentifier("settings-memory")
                } header: { Text(Agent.name) }

                Section {
                    // One switch: background listening that starts a conversation on "Hey Pixie".
                    // (Developer keeps the listener's separate options, including notify-only.)
                    Toggle(isOn: Binding(get: { (wake.enabled || wake.busy) && talkOnWake },
                                         set: { on in
                                             if on {
                                                 // Listening starts calls, so ask first.
                                                 let turnOn = {
                                                     talkOnWake = true
                                                     if !wake.enabled && !wake.busy { wake.start() }
                                                 }
                                                 if AIConsent.given { turnOn() } else { voice.requestConsent(then: turnOn) }
                                             } else {
                                                 wake.stop()
                                             }
                                         })) {
                        Text(wake.busy ? "Starting…" : "Listen for “\(Agent.wakePhrase)”")
                    }
                    .disabled(wake.busy)
                    .accessibilityIdentifier("simple-hands-free")
                    Toggle("Keep screen on while charging", isOn: $awakeWhileCharging)
                        .accessibilityIdentifier("simple-awake-charging")
                } header: { Text("Listening") } footer: {
                    Text("Listening hears “\(Agent.wakePhrase)”, even with the phone locked: say it and your request in one go. While charging, the screen stays on as long as Pixie is open.")
                }

                Section {
                    Toggle("\(Agent.name) can use the browser", isOn: $browserEnabled)
                        .accessibilityIdentifier("simple-browser-enabled")
                    BrowserSignInsLink()
                    ObsidianVaultRow()
                } header: { Text("Browser and notes") } footer: {
                    Text("With the browser on, \(Agent.name) can open, search and read websites; it keeps you signed in only to the sites you choose.")
                }

                if #available(iOS 26.0, *) {
                    Section {
                        NavigationLink("Alarms and Timers") { AlarmsView() }
                            .accessibilityIdentifier("settings-alarms")
                    } footer: {
                        Text("Alarms and timers \(Agent.name) set for you. Swipe one to cancel it.")
                    }
                }

                Section {
                    Toggle("Send voice to OpenAI in calls", isOn: $openAIConsent)
                        .accessibilityIdentifier("simple-openai-consent")
                    Link("Privacy Policy", destination: AIConsent.privacyPolicy)
                        .accessibilityIdentifier("simple-privacy-policy")
                } header: { Text("Privacy") } footer: {
                    Text("Calls with \(Agent.name) send your voice to OpenAI. Turn this off to stop that: no call starts until you agree again.")
                }

                Section {
                    Button("Show Setup Again") {
                        dismiss()
                        onboardingDone = false
                    }
                    .accessibilityIdentifier("settings-onboarding")
                    #if DEBUG
                    Button("Developer") { showDeveloper = true }
                        .accessibilityIdentifier("settings-developer")
                    #endif
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showDeveloper) { AdvancedView(controller: wake) }
            .navigationDestination(isPresented: $openMemory) { MemoryView() }
        }
    }
}

/// During a call: the orb, the conversation in Pixie's chat view as it happens (the same view
/// and rows as the chat log afterwards), and the call controls.
@available(iOS 18.0, *)
struct LiveCallScreen: View {
    @ObservedObject var voice: VoiceSessionController
    @ObservedObject var transcript: ChatTranscript
    let visualizer: VoiceVisualizer
    var orbSpace: Namespace.ID?
    /// The black panel fades in while the orb flies up from the start button.
    @State private var panelShown = false

    var body: some View {
        VStack(spacing: 0) {
            orb
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(panelShown ? 1 : 0), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)
                .onAppear { withAnimation(.easeOut(duration: 0.4)) { panelShown = true } }
            ConnectionBanner(state: voice.connection)
                .animation(.easeInOut(duration: 0.25), value: voice.connection)
            ChatTranscriptView(items: transcript.items, call: transcript.call, showsHeader: false)
                .accessibilityIdentifier("live-chat")
            ChatLengthWarning(tokens: voice.threadTokens)
            controls
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var orb: some View {
        if let orbSpace {
            visualizer.matchedGeometryEffect(id: "orb", in: orbSpace)
        } else {
            visualizer
        }
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

/// Shown on the call screen while the connection is weak or lost. While lost, the app keeps
/// what the user says and sends it once the link is back, so they can keep talking.
struct ConnectionBanner: View {
    let state: CallConnection.State

    var body: some View {
        if state != .good {
            Label(state == .lost ? "Connection lost. Keep talking, Pixie will catch up." : "Weak connection",
                  systemImage: state == .lost ? "wifi.exclamationmark" : "wifi")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state == .lost ? .orange : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("connection-banner")
        }
    }
}

/// Home, while the phone has no network: the orb is disabled underneath.
struct NetworkStatusBadge: View {
    var body: some View {
        Label("No internet connection", systemImage: "wifi.slash")
            .font(.headline)
            .foregroundStyle(.orange)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.orange.opacity(0.15), in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("network-status")
    }
}

/// After a call lost its network: what the user said since is kept as a voice note. Once the
/// network is back they can carry on the chat with it (Pixie hears it first) or discard it.
struct VoiceNoteCard: View {
    let note: VoiceSessionController.VoiceNote
    let online: Bool
    let resume: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if online {
                Label("Back online", systemImage: "wifi").font(.subheadline.weight(.semibold))
            } else {
                NetworkStatusBadge()
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(detail(at: context.date), systemImage: note.recording ? "record.circle" : "waveform")
                    .font(.footnote)
                    .foregroundStyle(note.recording ? .red : .secondary)
            }
            HStack {
                Button("Resume with Voice Note", systemImage: "play.fill", action: resume)
                    .buttonStyle(.borderedProminent)
                    .disabled(!online)
                    .accessibilityIdentifier("voice-note-resume")
                Spacer()
                Button("Discard", role: .destructive, action: discard)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("voice-note-discard")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("voice-note")
    }

    private func detail(at date: Date) -> String {
        let seconds = Int(min(HotAudioDevice.backlogSeconds, max(0, date.timeIntervalSince(note.since))))
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return note.recording ? "Recording what you say · \(length)" : "Voice note · \(length)"
    }
}
