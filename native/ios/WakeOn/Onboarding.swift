import AVFoundation
import SwiftUI

/// First-run setup: access (invite code or key), permission, a first call, the Action Button,
/// "Hey Lobby" listening and a demo of recorded calls. Every step after Welcome can be skipped;
/// steps that can't work yet (no code, no permission, no Action Button) are passed over.
enum Onboarding {
    static let doneKey = "onboarding.done"

    /// Suggested first questions, each showing something Lobby can do.
    static let prompts: [(label: String, icon: String, text: String)] = [
        ("Chart this week's weather", "chart.xyaxis.line", "Show me a chart of this week's weather where I am."),
        ("Where's the Eiffel Tower?", "map", "Where's the Eiffel Tower?"),
        ("What's in the news today?", "newspaper", "What's in the news today?"),
    ]

    /// iPhone 15 Pro and later have the Action Button.
    static var hasActionButton: Bool {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var info = utsname()
            uname(&info)
            id = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        guard id.hasPrefix("iPhone"), let major = Int(id.dropFirst(6).split(separator: ",").first ?? "") else { return false }
        return major >= 17 || id == "iPhone16,1" || id == "iPhone16,2"
    }
}

/// Opens the Settings app, where Action Button is one tap away. iOS has no link to the Action
/// Button page itself (iOS 26 sends deeper Settings links to Settings › Apps: tried
/// "App-Prefs:ACTION_BUTTON" on 2026-11-22), so this opens the top of Settings with the private
/// "App-Prefs:" link, falling back to Pixie's own settings page (the public link).
enum ActionButtonSettings {
    static let candidates = ["App-Prefs:", UIApplication.openSettingsURLString]

    @MainActor
    static func open() async -> Bool {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await UIApplication.shared.open(url) {
                VoiceSessionController.appLog("action_button_settings opened=\(candidate)")
                return true
            }
        }
        VoiceSessionController.appLog("action_button_settings opened=none")
        return false
    }
}

/// `wakeon://invite?code=alex-1-7k2mq9xd4r8w`: a friend's invite, filled in and checked.
@MainActor
final class InviteLink: ObservableObject {
    static let shared = InviteLink()
    @Published var code: String?

    static func code(from url: URL) -> String? {
        guard url.scheme == "wakeon", url.host == "invite" else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (code?.isEmpty ?? true) ? nil : code
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, access, permission, firstCall, actionButton, heyLobby, demo, done }

    @ObservedObject var wake: WakeController
    @ObservedObject var voice: VoiceSessionController = .shared
    @ObservedObject private var invite = InviteLink.shared
    @AppStorage(VoiceVisualizerSettings.styleKey) private var visualizerStyle: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var visualizerPalette = VoicePalette.default.name
    @AppStorage(ListenerSettings.Key.talkOnWake) private var talkOnWake = false
    let finish: () -> Void

    @State private var step: Step = OnboardingView.launchStep
    /// The current step's call happened (first call, Action Button press, "Hey Lobby").
    @State private var stepCallDone = false
    /// The first call just ended: the next page opens with a "That's a call" line.
    @State private var firstCallDone = false
    @State private var settingsLinkFailed = false
    @State private var practiceStarted = false
    /// Steps already passed (done or skipped), for Back.
    @State private var history: [Step] = []
    /// Hey Lobby sub-step: 0 say it, 1 dot and chime, 2 turn on, 3 try it, 4 done.
    @State private var heySub = 0
    @State private var chimePlayed = false
    @State private var listeningEnabled = false
    /// Listening's state before practice, put back if the step is left without turning it on.
    @State private var listeningBefore = false
    @State private var talkBefore = false
    @State private var chimePlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            Group {
                // The Hey Lobby step shows its call inside the card instead.
                if #available(iOS 18.0, *), voice.phase != .idle, step != .heyLobby, let chat = voice.liveChat {
                    LiveCallScreen(voice: voice, transcript: chat.transcript,
                                   visualizer: VoiceVisualizer(style: visualizerStyle, palette: .named(visualizerPalette)))
                } else {
                    page
                }
            }
            .toolbar {
                if !history.isEmpty, voice.phase == .idle {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { goBack() }
                            .accessibilityIdentifier("onboarding-back")
                    }
                }
                if step != .welcome, step != .done, voice.phase == .idle {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { advance() }.accessibilityIdentifier("onboarding-skip")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: voice.phase) { old, new in
            if old == .idle, new != .idle, callCounts(voice.lastTrigger) { stepCallDone = true }
            // After the first call, go straight on to the Action Button (no separate "done" page).
            if new == .idle, step == .firstCall, stepCallDone {
                advance()
                firstCallDone = true
            }
        }
        .onChange(of: invite.code) { _, code in if code != nil, step == .welcome { step = .access } }
    }

    /// Debug screenshots: `-onboarding-step 3` opens that step.
    private static var launchStep: Step {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-onboarding-step"), index + 1 < args.count,
           let raw = Int(args[index + 1]), let step = Step(rawValue: raw) { return step }
        #endif
        return .welcome
    }

    /// Which calls count for the current step.
    private func callCounts(_ trigger: String?) -> Bool {
        guard let trigger else { return false }
        switch step {
        case .firstCall: return true
        case .actionButton: return trigger.hasPrefix("app_intent")
        case .heyLobby: return trigger == "wake_word"
        default: return false
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            OnboardingPage(icon: "sparkles", title: "Meet Lobby",
                           text: "Lobby is a voice assistant you talk to like a person. Ask questions, find places, play music and look things up, hands-free.") {
                EmptyView()
            } actions: {
                primary("Get Started", id: "onboarding-start") { advance() }
            }
        case .access:
            APIKeyView(voice: voice, prefill: invite.code,
                       intro: "Enter the invite code a friend sent you, or your own OpenAI API key (starts with sk-).",
                       onValid: { invite.code = nil; advance() })
        case .permission:
            AIConsentPage(agree: {
                AIConsent.set(true)
                AVAudioApplication.requestRecordPermission { _ in
                    Task { @MainActor in advance() }
                }
            }, decline: { AIConsent.set(false); advance() })
        case .firstCall:
            OnboardingPage(icon: stepCallDone ? "checkmark.circle.fill" : "phone.bubble.fill",
                           title: stepCallDone ? "That's a call" : "Your first call",
                           text: stepCallDone
                               ? "Next, set it up so a single press starts one."
                               : "Tap a question to start. Lobby answers out loud. Say “bye” or tap End to hang up.") {
                if !stepCallDone {
                    VStack(spacing: 10) {
                        ForEach(Onboarding.prompts, id: \.label) { prompt in
                            Button {
                                voice.start(trigger: "onboarding", prompt: prompt.text)
                            } label: {
                                Label(prompt.label, systemImage: prompt.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Or just start talking") { voice.start(trigger: "onboarding") }
                            .padding(.top, 4)
                            .accessibilityIdentifier("onboarding-talk")
                    }
                }
            } actions: {
                if stepCallDone { primary("Next", id: "onboarding-next") { advance() } }
            }
        case .actionButton:
            OnboardingPage(note: firstCallDone ? callDoneNote : nil,
                           icon: stepCallDone ? "checkmark.circle.fill" : "button.vertical.left.press.fill",
                           title: stepCallDone ? "The Action Button works" : "One press to talk",
                           text: stepCallDone
                               ? "Press it any time, even with the phone locked. Press it again to hang up."
                               : "Pressing the Action Button opens Pixie and starts a call like the one you just had. Press it again to hang up.") {
                if !stepCallDone {
                    VStack(alignment: .leading, spacing: 10) {
                        OnboardingRow(icon: "1.circle", tint: .primary, textStyle: .primary, text: "Open Settings, then tap Action Button")
                        OnboardingRow(icon: "2.circle", tint: .primary, textStyle: .primary, text: "Swipe to Shortcut, then tap Choose a Shortcut")
                        OnboardingRow(icon: "3.circle", tint: .primary, textStyle: .primary, text: "Pick Pixie › Talk to Lobby")
                        OnboardingRow(icon: "4.circle", tint: .primary, textStyle: .primary, text: "Come back here and press the Action Button")
                    }
                    HStack(spacing: 12) {
                        ProgressView().frame(width: 28)
                        Text("Waiting for a press…").foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            } actions: {
                if stepCallDone {
                    primary("Next", id: "onboarding-next") { advance() }
                } else {
                    if settingsLinkFailed {
                        Text("Couldn't open it directly. Follow the steps above.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    primary("Open Settings", id: "onboarding-action-settings") {
                        Task { settingsLinkFailed = !(await ActionButtonSettings.open()) }
                    }
                }
            }
        case .heyLobby:
            // One sub-step at a time, each with its action and its feedback right here: the
            // phrase alone (practice, no call), what listening looks and sounds like, turning
            // listening on, then the whole thing end to end.
            OnboardingPage(note: firstCallDone ? callDoneNote : nil,
                           icon: "waveform", title: "Just say “Hey Lobby”",
                           text: "Listening runs on your iPhone, and nothing is sent until you say it.") {
                VStack(alignment: .leading, spacing: 20) {
                    OnboardingSubstep(number: 1, title: "Say “Hey Lobby”",
                                      result: "Heard you. That phrase wakes Lobby.", state: subState(0)) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Listening for “Hey Lobby”… Nothing starts a call yet.").foregroundStyle(.secondary)
                        }
                    }
                    OnboardingSubstep(number: 2, title: "What listening looks and sounds like",
                                      result: "Orange dot and chime.", state: subState(1)) {
                        VStack(alignment: .leading, spacing: 12) {
                            OnboardingRow(icon: "arrow.up",
                                          text: "Look at the top of the screen: the orange dot shows while the microphone is on, like now.")
                            OnboardingRow(icon: "bell.fill",
                                          text: "After “Hey Lobby”, this chime means Lobby is ready for your question. Words said during it are missed.")
                            HStack {
                                Button("Play the Chime", systemImage: "speaker.wave.2") { playChime(); chimePlayed = true }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("onboarding-play-chime")
                                Button("Got It") { heySub = 2 }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!chimePlayed)
                                    .accessibilityIdentifier("onboarding-got-it")
                            }
                        }
                    }
                    OnboardingSubstep(number: 3, title: "Turn on background listening",
                                      result: "Listening is on.", state: subState(2)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Then “Hey Lobby” works any time, even with the phone locked. It uses under 1% of battery an hour; turn it off in Settings.")
                                .foregroundStyle(.secondary)
                            Button("Turn On Background Listening") { turnOnListening() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("onboarding-listen")
                        }
                    }
                    OnboardingSubstep(number: 4, title: "Try it for real",
                                      result: "That's the whole flow.", state: subState(3)) {
                        if voice.phase != .idle {
                            InlineCall(voice: voice)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Say “Hey Lobby”, wait for the chime, then ask “what time is it?”")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } actions: {
                if heySub >= 4 { primary("Next", id: "onboarding-next") { advance() } }
            }
            .onAppear(perform: startPractice)
            .onChange(of: wake.detections) {
                if step == .heyLobby, heySub == 0 { heySub = 1 }
            }
            .onChange(of: voice.phase) { old, new in
                // The end-to-end call finished.
                if step == .heyLobby, heySub == 3, old != .idle, new == .idle, voice.lastTrigger == "wake_word" { heySub = 4 }
            }
        case .demo:
            OnboardingPage(icon: "play.rectangle.on.rectangle.fill", title: "See what Lobby can do",
                           text: "Recorded calls, played back as they happened.") {
                DemoList()
            } actions: {
                primary("Next", id: "onboarding-next") { advance() }
            }
        case .done:
            OnboardingPage(icon: "checkmark.seal.fill", title: "You're all set",
                           text: "Start a chat from the main screen, press the Action Button, or say “Hey Lobby”.") {
                EmptyView()
            } actions: {
                primary("Start Using Pixie", id: "onboarding-finish") { finish() }
            }
        }
    }

    private let callDoneNote = "That's a call. Start one any time from the main screen."

    private func subState(_ index: Int) -> SubstepState {
        heySub > index ? .done : heySub == index ? .current : .upcoming
    }

    /// Listening on without starting calls, so "Hey Lobby" can be practised. If listening was
    /// already on (and starting calls), it's restarted without calls: a detection never jumps
    /// to a call here.
    private func startPractice() {
        guard !practiceStarted, !listeningEnabled else { return }
        heySub = 0
        chimePlayed = false
        listeningBefore = wake.enabled || wake.busy
        talkBefore = talkOnWake
        talkOnWake = false
        practiceStarted = true
        if listeningBefore { wake.stop() }
        wake.start()
    }

    /// Sub-step 3: real listening, starting calls (restarted for a fresh detector).
    private func turnOnListening() {
        talkOnWake = true
        practiceStarted = false
        listeningEnabled = true
        wake.stop()
        wake.start()
        heySub = 3
    }

    private func playChime() {
        chimePlayer = try? AVAudioPlayer(data: HotAudioDevice.readyChimeWAV())
        chimePlayer?.play()
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier(id)
    }

    /// Back to the step before (one that was done or skipped).
    private func goBack() {
        guard let previous = history.popLast() else { return }
        leaveStep()
        step = previous
    }

    /// Leaving a step: put listening back as it was if practice didn't turn it on, reset state.
    private func leaveStep() {
        if practiceStarted {
            practiceStarted = false
            talkOnWake = talkBefore
            wake.stop()
            if listeningBefore { wake.start() }
        }
        stepCallDone = false
        firstCallDone = false
    }

    /// The next step that can work now.
    private func advance() {
        history.append(step)
        leaveStep()
        firstCallDone = false
        var next = Step(rawValue: step.rawValue + 1) ?? .done
        while next != .done, !available(next) { next = Step(rawValue: next.rawValue + 1) ?? .done }
        step = next
    }

    private func available(_ step: Step) -> Bool {
        let canCall = voice.keySource != "missing" && AIConsent.given
        switch step {
        case .access: return voice.keySource == "missing" || invite.code != nil
        case .permission: return voice.keySource != "missing" && !AIConsent.given
        case .firstCall, .heyLobby: return canCall
        case .actionButton: return canCall && Onboarding.hasActionButton
        case .welcome, .demo, .done: return true
        }
    }
}

/// An icon and a line of text, with every row's icon in the same fixed-width column so the
/// text lines up.
struct OnboardingRow: View {
    let icon: String
    var tint: Color = .secondary
    var small = false
    var textStyle: Color = .secondary
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .imageScale(small ? .small : .medium)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(textStyle)
        }
    }
}

/// A numbered sub-step: done ones collapse to a check and their result, the current one shows
/// its content, later ones are greyed.
enum SubstepState { case done, current, upcoming }

struct OnboardingSubstep<Content: View>: View {
    let number: Int
    let title: String
    let result: String
    let state: SubstepState
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(state == .done ? AnyShapeStyle(.green)
                                 : state == .current ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                    .foregroundStyle(state == .upcoming ? .tertiary : .primary)
                switch state {
                case .done: Text(result).font(.subheadline).foregroundStyle(.secondary)
                case .current: content
                case .upcoming: EmptyView()
                }
            }
        }
        .animation(.snappy, value: state)
    }
}

/// A call in progress, inside an onboarding card: what's happening, the last lines, End.
struct InlineCall: View {
    @ObservedObject var voice: VoiceSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(voice.status, systemImage: "waveform").font(.subheadline.weight(.semibold))
            ForEach(voice.transcript.suffix(3)) { line in
                Text("\(line.speaker): \(line.text)").font(.subheadline).foregroundStyle(.secondary)
            }
            Button("End", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-end-call")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One onboarding page: icon, title, text, the step's own content, and buttons at the bottom.
struct OnboardingPage<Content: View, Actions: View>: View {
    /// A line above the icon about the step before ("That's a call").
    var note: String? = nil
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .padding(.bottom, 8)
                }
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title).font(.title2.bold())
                Text(text)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) { actions }
                .padding()
        }
    }
}

/// The recorded sample calls (also used by Chat Lab), each played back on tap.
struct DemoList: View {
    private let calls: [CapturedCall] = (Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: nil) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap(CapturedCall.load)

    var body: some View {
        VStack(spacing: 10) {
            ForEach(calls) { call in
                if #available(iOS 18.0, *) {
                    NavigationLink { DemoReplayView(call: call) } label: {
                        Label(call.title, systemImage: "play.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// A recorded call played back at its own timing in Lobby's chat view.
@available(iOS 18.0, *)
struct DemoReplayView: View {
    let call: CapturedCall
    @StateObject private var player = DemoPlayer()

    var body: some View {
        ChatTranscriptView(items: player.items, call: player.call, showsHeader: false)
            .navigationTitle(call.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Replay", systemImage: "arrow.counterclockwise") { play() }
            }
            .onAppear(perform: play)
            .onDisappear { player.stop() }
    }

    private func play() { player.play(CaptureReplay(lines: call.lines, rawEvents: false).steps) }
}

/// Applies replay steps over time (Chat Lab's LabPlayer, without its lab controls).
@MainActor
final class DemoPlayer: ChatTranscript {
    private var task: Task<Void, Never>?

    func play(_ steps: [ChatStep]) {
        task?.cancel()
        items = []
        call = ChatCallState()
        touched()
        let steps = steps.sorted { $0.at < $1.at }
        let start = Date()
        task = Task { @MainActor [weak self] in
            for step in steps {
                let wait = step.at - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled else { return }
                step.apply(self)
            }
        }
    }

    func stop() { task?.cancel() }
}
