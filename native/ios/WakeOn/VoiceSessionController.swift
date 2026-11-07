import AVFoundation
import Combine
import Darwin
import Foundation
import QuartzCore
import UIKit

/// Owns one realtime voice call at a time and measures every step of it.
///
/// Three kinds of traces go to `latency.jsonl` (see `LatencyTrace`):
/// - `voice_setup:<trigger>`: trigger → audio session → WebRTC offer → HTTP → connected → first audio.
/// - `voice_turn`: user stops talking → first reply transcript → reply audio starts, with any
///   delegated (web search) work nested inside.
/// - `voice_probe:<kind>`: scripted requests for the simulator, where nobody is talking.
@MainActor
final class VoiceSessionController: ObservableObject {
    static let shared = VoiceSessionController()

    enum Phase: Equatable { case idle, connecting, live, ending }
    enum Probe: String { case greeting, search }

    struct TimelineRow: Identifiable { let id = UUID(); let name: String; let ms: Double }
    struct TranscriptLine: Identifiable { let id = UUID(); let speaker: String; var text: String }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Not connected"
    @Published private(set) var timeline: [TimelineRow] = []
    @Published private(set) var transcript: [TranscriptLine] = []
    /// Trigger → server ready and microphone audio flowing.
    @Published private(set) var listeningMs: Double?
    @Published private(set) var lastResponseMs: Double?
    @Published private(set) var responseHistory: [Double] = []
    @Published private(set) var roundTripMs: Double?
    @Published private(set) var jitterBufferMs: Double?
    @Published private(set) var usageSeconds: Double?
    @Published private(set) var muted = false
    @Published var error: String?
    @Published private(set) var keySource: String = OpenAIKeyStore.load()?.source.rawValue ?? "missing"

    var medianResponseMs: Double? {
        guard !responseHistory.isEmpty else { return nil }
        return responseHistory.sorted()[responseHistory.count / 2]
    }

    private var provider: OpenAILiveVoiceProvider?
    private var setupTrace: LatencyTrace?
    private var turn: Exchange?
    private var probeRun: Exchange?
    private var exchanges: [Exchange] { [turn, probeRun].compactMap { $0 } }
    private var probe: Probe?
    private var tracker = TurnTracker()
    private var setupOrigin: UInt64 = 0
    private var sessionStarted = false
    private var microphoneLive = false
    private var listeningMarked = false
    private var localListening = false
    /// Trigger → server ready and audio leaving the phone.
    @Published private(set) var reachingMs: Double?
    private var firstAudio = false
    /// The wake listener was on (or paused) when this call started and comes back after it.
    private(set) var resumeWakeListener = false
    private var lastInputEndMs: Int?
    private var backendSeen: [String: Set<String>] = [:]
    private var lastSpeaker: String?
    private var interruption: NSObjectProtocol?
    private var callStarted: UInt64 = 0
    /// Setup marks are collected here and published once, so SwiftUI does not redraw
    /// the screen on the main thread between every setup step.
    private var pendingTimeline: [TimelineRow] = []
    private var lastStatsPublish: Double = 0
    private var lastLevelLog: Double = 0
    private var serverEventCounts: [String: Int] = [:]
    /// Silence before hanging up after Lobby says "Bye", or after it asks "Anything else?".
    static let endSilenceSeconds = 2.0
    private var goodbyeHeard = false
    /// Quiet time (no speech, no lookup) before checking in, and again before ending the call.
    static let idleSecondsKey = "voice.idleSeconds"
    static var idleSeconds: Double {
        let value = UserDefaults.standard.object(forKey: idleSecondsKey) as? Double ?? 10
        return max(0, value)
    }
    private var lastActivity: Double?
    private var nudgedAt: Double?
    /// Lobby has started speaking its check-in since the nudge.
    private var checkInSpoken = false
    private var lookingUpSince: Double?

    private init() {}

    // MARK: - Control

    /// Starts a call. `origin` is when the trigger happened (an Action Button press, a tap).
    func start(trigger: String, origin: UInt64 = DispatchTime.now().uptimeNanoseconds, probe: Probe? = nil) {
        if phase != .idle {
            WakeController.shared.cancelHandover()
            if phase == .live, let probe { runProbe(probe); return }
            // A second Action Button press hangs up.
            if trigger.hasPrefix("app_intent") { stop(reason: "action_button") }
            return
        }
        // Fast path first, before any bookkeeping or UI work: free the microphone, start audio,
        // and send the prepared offer. Timestamps are written into the trace afterwards.
        let wake = WakeController.shared
        // Bring the listener back after the call if it was on, or paused waiting to resume.
        resumeWakeListener = wake.enabled || wake.autoResumePending
        wake.cancelAutoResume()
        // A wake-word start keeps the listener recording until the call's microphone runs.
        let handover = wake.handingOver
        let wakeWasActive = !handover && (wake.enabled || wake.busy || wake.isPlaying)
        if wakeWasActive { wake.stop(reason: "voice_call", releaseSession: false) }
        let wakeStopped = DispatchTime.now().uptimeNanoseconds
        let inBackground = UIApplication.shared.applicationState == .background
        earlyArmTried = false
        if OpenAILiveVoiceProvider.useHotAudio {
            let device = HotAudioDevice.shared
            device.onFirstCapture = { [weak self] in
                let time = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in
                    self?.markLocalListening(at: time)
                    // The listener's chunks arrive ~100–200 ms late; never hold the call longer.
                    if WakeController.shared.handingOver {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            WakeController.shared.completeHandover(reason: "watchdog")
                        }
                    }
                }
            }
            device.onBridgeMerged = { [weak self] frames, gapMs, tailDb in
                let time = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in
                    self?.record("wake_bridge_merged", at: time, fields: ["bridgeMs": Double(frames) / 48.0, "seamGapMs": gapMs,
                                                                         "tailDb": tailDb])
                    self?.log(String(format: "wake bridge merged bridgeMs=%.0f seamGapMs=%.1f tailDb=%.0f",
                                     Double(frames) / 48.0, gapMs, tailDb))
                }
            }
            device.onBacklogDrained = { [weak self] frames in
                let time = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in
                    self?.record("backlog_sent", at: time, fields: ["backlogMs": Double(frames) / 48.0])
                    self?.log(String(format: "backlog sent backlogMs=%.0f", Double(frames) / 48.0))
                }
            }
            #if DEBUG
            device.onBacklogDump = { pcm in
                // Write off the audio thread: Documents/backlog-<time>.wav (16-bit, 48 kHz, mono).
                DispatchQueue.global(qos: .utility).async {
                    var wav = Data()
                    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
                    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
                    wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
                    wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
                    wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); wav.append(pcm)
                    let name = "backlog-\(Int(Date().timeIntervalSince1970)).wav"
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                    try? wav.write(to: url)
                }
            }
            #endif
            device.beginBuffering()
        }
        if OpenAILiveVoiceProvider.useHotAudio {
            // Experiment: a wake word heard in the background tries to start audio right away,
            // in a shared session, instead of waiting for the app to come forward.
            let backgroundWake = inBackground && trigger == "wake_word"
            HotAudioDevice.shared.backgroundStart = backgroundWake
            // A wake-word call has no screen to watch: a chime says when the microphone records.
            HotAudioDevice.shared.chimeOnFirstCapture = trigger == "wake_word"
            HotAudioDevice.shared.onChime = { [weak self] in
                let time = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in self?.record("ready_chime", at: time) }
            }
            HotAudioDevice.shared.mayArm = !inBackground || backgroundWake
            if inBackground && !backgroundWake { armWhenActive() } else { armAudio() }
        }
        let credentials = OpenAIKeyStore.load()
        let permitted = AVAudioApplication.shared.recordPermission == .granted
        let provider = takePrepared() ?? OpenAILiveVoiceProvider(config: Self.makeConfig())
        self.provider = provider
        provider.onEvent = { [weak self, weak provider] event in
            guard let self, let provider, self.provider === provider else { return }
            self.handle(event)
        }
        let sentAt = (credentials != nil && permitted) ? provider.sendPreparedOffer(apiKey: credentials!.key) : nil

        let trace = LatencyTrace(source: "voice_setup:\(trigger)", origin: origin)
        trace.mark("start_entered", fields: ["processAgeMs": Self.processAgeMs(at: origin) ?? -1,
                                             "appState": UIApplication.shared.applicationState.rawValue])
        log("start trigger=\(trigger)")
        setupTrace = trace
        setupOrigin = origin
        callStarted = origin
        self.probe = probe
        phase = .connecting
        // With local buffering, speech is kept from the moment the microphone starts (well
        // within a person's reaction time to this cue), so say "Listening" right away.
        status = OpenAILiveVoiceProvider.useHotAudio ? "Listening" : "Connecting…"
        error = nil
        timeline = []
        pendingTimeline = []
        lastStatsPublish = 0
        transcript = []
        lastResponseMs = nil
        roundTripMs = nil
        jitterBufferMs = nil
        usageSeconds = nil
        muted = false
        VoiceAudioTap.shared.microphoneMuted = false
        tracker = TurnTracker()
        sessionStarted = false
        firstAudio = false
        microphoneLive = false
        listeningMarked = false
        localListening = false
        listeningMs = nil
        reachingMs = nil
        lastInputEndMs = nil
        backendSeen = [:]
        lastSpeaker = nil
        serverEventCounts = [:]
        goodbyeHeard = false
        lastActivity = nil
        nudgedAt = nil
        checkInSpoken = false
        lookingUpSince = nil
        record("start_entered", at: origin + 1)
        if OpenAILiveVoiceProvider.useHotAudio {
            record("listening_shown")
            FirstFrameProbe.shared.arm { [weak self] time in self?.record("first_frame_after_trigger", at: time) }
        }
        if wakeWasActive { record("wake_listener_stopped", at: wakeStopped) }
        if let sentAt { record("http_request_begin", at: sentAt, fields: ["prepared": true]) }

        guard let (key, source) = credentials else {
            provider.close(reason: "no_key")
            fail("Add an OpenAI API key first.")
            return
        }
        keySource = source.rawValue
        Task { await self.connect(apiKey: key, provider: provider, permitted: permitted) }
    }

    /// Started from the background (fast-start intent): arm the moment the app is active.
    private var activeObserver: NSObjectProtocol?
    private func armWhenActive() {
        log("audio deferred: app in background")
        // Do everything except starting the microphone now, so becoming active only has to start it.
        HotAudioDevice.shared.prebuildAsync { [weak self] result in
            let time = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in
                switch result {
                case .success(let timing):
                    self?.record("audio_prebuilt", at: time, fields: ["sessionMs": timing.sessionMs, "buildMs": timing.buildMs,
                                                                      "sessionActive": timing.sessionActive])
                case .failure(let error):
                    self?.record("audio_prebuild_failed", at: time, fields: ["error": error.localizedDescription])
                }
            }
        }
        // Try as soon as the app is in the foreground (still inactive), ~250 ms before it becomes
        // active. If iOS refuses the microphone that early, the active notification retries.
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIScene.willEnterForegroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            let time = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated { self?.armEarly(reason: "will_enter_foreground", at: time) }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            let time = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.activeObserver { NotificationCenter.default.removeObserver(observer) }
                if let observer = self.foregroundObserver { NotificationCenter.default.removeObserver(observer) }
                self.activeObserver = nil
                self.foregroundObserver = nil
                self.record("app_became_active", at: time)
                HotAudioDevice.shared.mayArm = true
                // Arming again is a no-op if the early attempt already started the engine.
                if self.phase == .connecting || self.phase == .live { self.armAudio() }
            }
        }
    }

    private var foregroundObserver: NSObjectProtocol?
    private var earlyArmTried = false

    /// One early attempt to start the microphone before the app is fully active.
    private func armEarly(reason: String, at time: UInt64) {
        guard !earlyArmTried, phase == .connecting || phase == .live, OpenAILiveVoiceProvider.useHotAudio else { return }
        earlyArmTried = true
        record("early_arm_\(reason)", at: time, fields: ["appState": UIApplication.shared.applicationState.rawValue])
        let device = HotAudioDevice.shared
        device.mayArm = true
        device.armAsync { [weak self] result in
            let done = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in
                switch result {
                case .success(let timing):
                    self?.record("audio_armed", at: done, fields: ["sessionMs": timing.sessionMs, "engineMs": timing.engineMs,
                                                                   "early": true])
                case .failure(let error):
                    // Too early for iOS: wait for the app to become active.
                    device.mayArm = UIApplication.shared.applicationState == .active
                    self?.record("early_arm_refused", at: done, fields: ["error": error.localizedDescription])
                }
            }
        }
    }

    /// Marks when iOS finished bringing the app to the front for a fast-start intent.
    func noteForegrounded(at time: UInt64) {
        record("continued_in_foreground", at: time)
        armEarly(reason: "continued_in_foreground", at: time)
    }

    /// Starts audio now, in parallel with signalling (~400 ms on an iPhone 17 Pro).
    private func armAudio() {
        let device = HotAudioDevice.shared
        device.onTrace = { [weak self] message in
            let time = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in self?.record("device:" + message.split(separator: " ").first.map(String.init)!, at: time,
                                              fields: ["detail": message]) }
        }
        device.onFirstDelivery = { [weak self] in
            let time = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in self?.record("microphone_delivered_to_webrtc", at: time) }
        }
        device.armAsync { [weak self] result in
            let time = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in
                switch result {
                case .success(let timing):
                    self?.record("audio_armed", at: time,
                                 fields: ["sessionMs": timing.sessionMs, "engineMs": timing.engineMs,
                                          "alreadyArmed": timing.alreadyArmed, "inputRate": timing.inputRate,
                                          "outputRate": timing.outputRate, "ioBufferMs": timing.ioBufferMs])
                case .failure(let error):
                    self?.log("audio_arm_failed error=\(WakeController.describe(error)) appState=\(UIApplication.shared.applicationState.rawValue)")
                    self?.fail("Audio could not start: \(error.localizedDescription)")
                    // Without audio the call is useless: hang up instead of sitting connected and silent.
                    self?.provider?.close(reason: "audio_failed")
                }
            }
        }
    }

    func stop(reason: String = "user") {
        guard let provider, phase == .connecting || phase == .live else { return }
        phase = .ending
        status = "Ending…"
        log("stop reason=\(reason)")
        var chimeDelay: Duration = .zero
        if OpenAILiveVoiceProvider.useHotAudio {
            // Hang-up chime: keep the call's audio running until it has played, and keep the
            // model from hearing it.
            provider.setMuted(true)
            HotAudioDevice.shared.playEndChime()
            chimeDelay = .milliseconds(Int(HotAudioDevice.endChimeSeconds * 1000) + 100)
        }
        Task {
            try? await Task.sleep(for: chimeDelay)
            provider.requestClose()
            // session.closed normally arrives within a few hundred ms; do not wait on a dead network.
            try? await Task.sleep(for: .seconds(2))
            if self.provider === provider { provider.close(reason: reason) }
        }
    }

    func toggleMute() {
        muted.toggle()
        provider?.setMuted(muted)
        VoiceAudioTap.shared.microphoneMuted = muted
    }

    func saveKey(_ key: String) {
        do {
            try OpenAIKeyStore.save(key)
            keySource = OpenAIKeyStore.Source.keychain.rawValue
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func forgetKey() {
        OpenAIKeyStore.delete()
        keySource = OpenAIKeyStore.load()?.source.rawValue ?? "missing"
    }

    // MARK: - Prepared call

    /// One call built ahead of time (peer, offer, candidates): no cost, no microphone.
    private var prepared: OpenAILiveVoiceProvider?
    private var preparedSince: UInt64 = 0
    private static let preparedMaxAge: UInt64 = 300 * 1_000_000_000

    /// Builds the next call's offer now, so a trigger can send it immediately.
    func prepareNext() {
        guard phase == .idle else { return }
        _ = OpenAIKeyStore.load() // warm the in-memory key
        if let prepared, DispatchTime.now().uptimeNanoseconds - preparedSince < Self.preparedMaxAge { return }
        prepared?.close(reason: "stale")
        let provider = OpenAILiveVoiceProvider(config: Self.makeConfig())
        prepared = provider
        preparedSince = DispatchTime.now().uptimeNanoseconds
        Task {
            await OpenAILiveVoiceProvider.warmup.wait()
            do { try await provider.prepare() } catch {
                if self.prepared === provider { self.prepared = nil }
            }
        }
    }

    private func takePrepared() -> OpenAILiveVoiceProvider? {
        defer { prepared = nil }
        guard let prepared, DispatchTime.now().uptimeNanoseconds - preparedSince < Self.preparedMaxAge else {
            prepared?.close(reason: "stale")
            return nil
        }
        return prepared
    }

    static func makeConfig() -> LiveVoiceConfig {
        var config = LiveVoiceConfig()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--no-delegation") { config.delegation = false }
        if args.contains("--no-web-search") { config.webSearch = false }
        if let index = args.firstIndex(of: "--ice-quiet"), index + 1 < args.count, let ms = Int(args[index + 1]) {
            config.iceQuietPeriod = ms <= 0 ? .seconds(60) : .milliseconds(ms)
        }
        if let index = args.firstIndex(of: "--effort"), index + 1 < args.count {
            config.delegationReasoningEffort = args[index + 1] == "default" ? nil : args[index + 1]
        }
        #endif
        return config
    }

    // MARK: - Connection

    private func connect(apiKey: String, provider: OpenAILiveVoiceProvider, permitted: Bool) async {
        record("connect_task_begin")
        if !permitted {
            let granted = await AVAudioApplication.requestRecordPermission()
            record("microphone_permission", fields: ["granted": granted])
            guard granted else {
                provider.close(reason: "no_permission")
                return fail("Microphone access is off. Turn it on in Settings › Wake On.")
            }
        }
        guard phase == .connecting, self.provider === provider else { return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--end-after"), index + 1 < args.count, let seconds = Double(args[index + 1]) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.stop(reason: "end_after")
            }
        }
        #endif
        observeInterruptions()
        do {
            try await provider.start(apiKey: apiKey)
        } catch {
            if self.provider === provider {
                provider.close(reason: "setup_failed")
                fail(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: LiveVoiceEvent) {
        switch event {
        case let .milestone(name, time, fields):
            record(name, at: time, fields: fields)
            if name == "first_audio_packet_received" {
                firstAudio = true
                finishSetupIfReady()
            }
            if name == "first_microphone_packet_sent" {
                microphoneLive = true
                markListening()
            }
        case let .server(json, time):
            handleServer(json, at: time)
        case let .stats(stats):
            handleStats(stats)
        case let .ended(reason):
            finishCall(reason: reason)
        }
    }

    // MARK: - Server events

    private func handleServer(_ json: [String: Any], at time: UInt64) {
        let type = json["type"] as? String ?? "unknown"
        serverEventCounts[type, default: 0] += 1
        switch type {
        case "session.started":
            sessionStarted = true
            record("session_started", at: time)
            phase = .live
            if !localListening { status = "Connecting… almost ready" }
            if OpenAILiveVoiceProvider.useHotAudio {
                HotAudioDevice.shared.enableVoiceProcessing()
                HotAudioDevice.shared.released = true
            }
            markListening()
            finishSetupIfReady()
            if let probe { runProbe(probe) }
        case "session.input_transcript.delta":
            let heard = json["delta"] as? String ?? ""
            appendTranscript("You", heard)
            lastInputEndMs = json["end_ms"] as? Int
            // Words from the user (not just mic noise or echo) answer a check-in.
            if heard.contains(where: \.isLetter) { nudgedAt = nil; checkInSpoken = false }
        case "session.output_transcript.delta":
            let seconds = uptimeSeconds(time)
            if lastSpeaker != "Lobby" {
                // First reply fragment of this turn: compare the server's own timeline too.
                var fields: [String: Any] = [:]
                if let start = json["start_ms"] as? Int, let inputEnd = lastInputEndMs {
                    fields["serverGapMs"] = start - inputEnd
                }
                exchanges.forEach { $0.outputTranscript(at: time, fields: fields) }
            } else {
                exchanges.forEach { $0.outputTranscript(at: time, fields: [:]) }
            }
            tracker.noteAssistantTranscript(at: seconds)
            appendTranscript("Lobby", json["delta"] as? String ?? "")
            if nudgedAt != nil { checkInSpoken = true }
            // Follows Lobby's latest line: a reply that goes on after "bye", or a new reply to
            // something the user said after the goodbye, cancels the hang-up.
            let bye = transcript.last.map { $0.speaker == "Lobby" && Self.endsWithBye($0.text) } ?? false
            if bye != goodbyeHeard {
                goodbyeHeard = bye
                if bye {
                    record("goodbye_heard", at: time)
                    log("goodbye heard: hanging up after \(Int(Self.endSilenceSeconds)) s of silence")
                } else {
                    log("goodbye cancelled: Lobby kept talking")
                }
            }
        case "session.delegation.created":
            let delegation = json["delegation"] as? [String: Any] ?? [:]
            let fields: [String: Any] = ["target": delegation["target"] as? String ?? "",
                                         "offsetMs": json["offset_ms"] as? Int ?? -1]
            exchanges.forEach { $0.delegationCreated(at: time, fields: fields) }
            log("delegation target=\(fields["target"] ?? "")")
            lookingUpSince = uptimeSeconds(time)
            status = "Live · looking it up"
        case "response.event":
            let nested = (json["event"] as? [String: Any])?["type"] as? String ?? "unknown"
            let delegation = json["delegation_id"] as? String ?? "none"
            if nested == "response.output_item.done",
               let item = (json["event"] as? [String: Any])?["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                handleFunctionCall(item)
            }
            var seen = backendSeen[delegation, default: []]
            if seen.insert(nested).inserted {
                backendSeen[delegation] = seen
                // First occurrence of each backend stage: created, web search, first token, completed.
                exchanges.forEach { $0.backend(nested, at: time) }
                log("backend \(nested)")
            }
            if nested == "response.completed" || nested == "response.failed" || nested == "response.incomplete" {
                lookingUpSince = nil
            }
            if nested == "response.completed", phase == .live { status = "Live · speak now" }
        case "session.usage.updated":
            usageSeconds = (json["usage"] as? [String: Any])?["seconds"] as? Double
        case "session.closed":
            let reason = json["reason"] as? String ?? "closed"
            usageSeconds = ((json["usage"] as? [String: Any])?["seconds"] as? Double) ?? usageSeconds
            record("session_closed", at: time, fields: ["reason": reason])
            provider?.close(reason: reason)
        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Unknown error"
            log("server error \(message)")
            error = message
        case "info":
            log("info \(json["code"] as? String ?? "") \(json["message"] as? String ?? "")")
        default:
            break
        }
    }

    /// The backend model called one of the app's tools (only play_spotify so far).
    private func handleFunctionCall(_ item: [String: Any]) {
        let name = item["name"] as? String ?? ""
        let callID = item["call_id"] as? String ?? ""
        let arguments = (item["arguments"] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        log("function_call name=\(name) arguments=\(item["arguments"] as? String ?? "")")
        var result = "unknown tool"
        if name == SpotifyPlayer.toolName,
           let request = SpotifyPlayer.request(spotifyURL: arguments["spotify_url"] as? String ?? "",
                                               query: arguments["query"] as? String ?? "",
                                               title: arguments["title"] as? String ?? "") {
            result = "Opening \(request.title) in Spotify; the call is ending."
            pendingSpotify = request
        } else if name == SpotifyPlayer.toolName {
            result = "Nothing to play: no link and no query."
        }
        // Every call needs an output before the backend can go on (see OpenAI's delegation guide).
        provider?.send(["type": "response.item.create",
                        "item": ["type": "function_call_output", "call_id": callID, "output": result]])
        provider?.send(["type": "response.create"])
        // Spotify's playback would fight the call for audio: hang up, then open it (finishCall).
        if pendingSpotify != nil { stop(reason: "spotify") }
    }

    /// Opened once the call has ended and released the audio session.
    private var pendingSpotify: SpotifyPlayer.Request?

    private func appendTranscript(_ speaker: String, _ delta: String) {
        guard !delta.isEmpty else { return }
        #if DEBUG
        if lastSpeaker != speaker, let previous = transcript.last { log("transcript \(previous.speaker): \(previous.text)") }
        #endif
        if lastSpeaker == speaker, !transcript.isEmpty {
            transcript[transcript.count - 1].text += delta
        } else {
            transcript.append(TranscriptLine(speaker: speaker, text: delta))
            if transcript.count > 30 { transcript.removeFirst(transcript.count - 30) }
        }
        lastSpeaker = speaker
    }

    // MARK: - Turn timing

    private func handleStats(_ stats: LiveVoiceStats) {
        #if DEBUG
        if stats.time - lastLevelLog >= 1 {
            lastLevelLog = stats.time
            log(String(format: "level mic=%.3f reply=%.3f speaking=%@", tracker.microphone.lastLevel,
                       tracker.assistant.lastLevel, tracker.microphone.active ? "yes" : "no"))
        }
        #endif
        if stats.time - lastStatsPublish >= 0.5 {
            lastStatsPublish = stats.time
            if let rtt = stats.roundTripMs, rtt != roundTripMs { roundTripMs = rtt }
            if let jitter = stats.jitterBufferMs { jitterBufferMs = (jitter * 10).rounded() / 10 }
        }
        checkInactivity(at: stats.time)
        let events = tracker.ingest(time: stats.time,
                                    microphoneEnergy: muted ? nil : stats.microphoneEnergy,
                                    microphoneDuration: muted ? nil : stats.microphoneDuration,
                                    remoteEnergy: stats.remoteEnergy, remoteDuration: stats.remoteDuration)
        for event in events {
            switch event {
            case .userStarted:
                turn?.finish("no_reply")
                turn = nil
                lastSpeaker = nil
            case let .userStopped(spoken):
                guard let end = spoken.userEnd else { continue }
                let exchange = Exchange(source: "voice_turn", origin: UInt64(end * 1e9))
                exchange.trace.mark("user_speech_end", fields: ["userSpeechMs": (end - spoken.userStart) * 1000])
                turn = exchange
                lastSpeaker = nil
            case let .assistantStarted(spoken):
                let time = UInt64((spoken?.assistantAudioStart ?? stats.time) * 1e9)
                if let probe = probeRun, probe.audioStarted(at: time) {
                    finish(probe, stats: stats)
                    probeRun = nil
                }
                guard let exchange = turn else { continue }
                let first = !exchange.heardReply
                let done = exchange.audioStarted(at: time)
                if first, let latency = spoken?.responseLatency {
                    lastResponseMs = latency * 1000
                    responseHistory.append(latency * 1000)
                    exchange.responseMs = latency * 1000
                    log(String(format: "turn responseMs=%.0f rttMs=%.0f jitterMs=%.0f", latency * 1000,
                               stats.roundTripMs ?? -1, stats.jitterBufferMs ?? -1))
                }
                if done {
                    finish(exchange, stats: stats)
                    turn = nil
                }
            case let .assistantStopped(seconds):
                let time = UInt64(seconds * 1e9)
                if let probe = probeRun, probe.audioStopped(at: time) { finish(probe, stats: stats); probeRun = nil }
                if let exchange = turn, exchange.audioStopped(at: time) { finish(exchange, stats: stats); turn = nil }
            case .bargeIn:
                break
            }
        }
    }

    private func finish(_ exchange: Exchange, stats: LiveVoiceStats) {
        var extra: [String: Any] = ["delegated": exchange.delegated]
        if let ms = exchange.responseMs { extra["responseMs"] = ms }
        exchange.finish("answered", fields: summary(stats, extra: extra))
        log("\(exchange.source) answered " + exchange.milestones)
    }

    private func summary(_ stats: LiveVoiceStats, extra: [String: Any] = [:]) -> [String: Any] {
        var fields = extra
        fields["roundTripMs"] = stats.roundTripMs ?? -1
        fields["jitterBufferMs"] = stats.jitterBufferMs ?? -1
        fields["concealedSamples"] = stats.concealedSamples
        fields["packetsReceived"] = stats.packetsReceived
        fields["packetsSent"] = stats.packetsSent
        return fields
    }

    // MARK: - Probes (simulator: no one is talking)

    private func runProbe(_ probe: Probe) {
        probeRun?.finish("superseded")
        let exchange = Exchange(source: "voice_probe:\(probe.rawValue)")
        probeRun = exchange
        self.probe = nil
        switch probe {
        case .greeting:
            provider?.send(["type": "session.commentary.append", "delegation_id": NSNull(),
                            "content": "Greet the user in five words or fewer."])
        case .search:
            provider?.send(["type": "response.item.create",
                            "item": ["type": "message", "role": "user",
                                     "content": [["type": "input_text",
                                                  "text": "Search the web: what is the current weather in Toronto?"]]]])
            provider?.send(["type": "response.create"])
        }
        exchange.trace.mark("probe_sent")
        log("probe \(probe.rawValue) sent")
    }

    // MARK: - Lifecycle

    /// "Listening": the server is ready and the user's audio is reaching it. This is the
    /// number the app's own overhead is judged by.
    /// Server ready and the user's audio is leaving the phone.
    private func markListening() {
        guard sessionStarted, microphoneLive, !listeningMarked else { return }
        listeningMarked = true
        record("audio_reaching_openai")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - setupOrigin) / 1e6
        reachingMs = ms
        log(String(format: "reaching triggerToReachingOpenAIMs=%.0f", ms))
        if !OpenAILiveVoiceProvider.useHotAudio { markLocalListening(at: DispatchTime.now().uptimeNanoseconds) }
    }

    /// Ends the call after a goodbye followed by silence; checks in, then ends, when idle.
    private func checkInactivity(at time: Double) {
        guard phase == .live, sessionStarted else { return }
        // A lookup counts as activity, but never for more than 30 s.
        let lookingUp = lookingUpSince.map { time - $0 < 30 } ?? false
        if tracker.microphone.active || tracker.assistant.active || lookingUp || lastActivity == nil {
            // Mic sound only delays the hang-up; it can be echo or noise. Cancelling waits for
            // words: the transcript (see the transcript events).
            lastActivity = time
            return
        }
        guard let last = lastActivity else { return }
        let quiet = time - last
        if goodbyeHeard, quiet >= Self.endSilenceSeconds {
            log(String(format: "ending after goodbye quietMs=%.0f", quiet * 1000))
            stop(reason: "goodbye")
            return
        }
        let idle = Self.idleSeconds
        guard idle > 0, !goodbyeHeard else { return }
        if let nudged = nudgedAt {
            // Checked in and still no answer: end shortly after the question, or after the
            // full silence time if Lobby never asked it.
            let answered = checkInSpoken ? quiet >= Self.endSilenceSeconds : time - nudged >= idle && quiet >= idle
            guard answered else { return }
            log(String(format: "ending after no answer to check-in quietMs=%.0f", quiet * 1000))
            stop(reason: "idle")
        } else {
            guard quiet >= idle else { return }
            nudgedAt = time
            log(String(format: "nudge after quietMs=%.0f", quiet * 1000))
            record("inactivity_nudge")
            provider?.sendCommentary("The user has been quiet for \(Int(idle)) seconds. "
                + "Check in with one short question, such as \"Anything else?\"")
        }
    }

    /// True when an assistant line ends with the word "bye" ("Okay, bye.", "Bye-bye!").
    nonisolated static func endsWithBye(_ text: String) -> Bool {
        let trimmed = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard trimmed.hasSuffix("bye") else { return false }
        let before = trimmed.dropLast(3)
        return before.isEmpty || before.last.map { !$0.isLetter } ?? true || before.hasSuffix("good")
    }

    /// The wake listener stopped after handing its microphone to this call.
    func listenerHandedOver(reason: String) {
        record("wake_listener_stopped", fields: ["handover": reason])
    }

    /// The microphone is capturing: what the user says from now on is kept (and sent once
    /// connected), so the app can say "Listening" before OpenAI is reachable.
    private func markLocalListening(at time: UInt64) {
        guard !localListening, phase == .connecting || phase == .live else { return }
        localListening = true
        if status != "Listening" { status = "Listening" }
        record("mic_live", at: time)
        let ms = Double(time - setupOrigin) / 1e6
        listeningMs = ms
        log(String(format: "mic_live triggerToMicLiveMs=%.0f", ms))
    }

    private func finishSetupIfReady() {
        guard sessionStarted, firstAudio, listeningMarked, let trace = setupTrace else { return }
        if let listeningMs { trace.mark("listening_ms_summary", fields: ["listeningMs": listeningMs, "reachingMs": reachingMs ?? -1]) }
        let readyMs = Double(DispatchTime.now().uptimeNanoseconds - setupOrigin) / 1e6
        trace.finish("connected", fields: ["readyMs": readyMs])
        timeline = pendingTimeline
        setupTrace = nil
        log(String(format: "setup readyMs=%.0f", readyMs))
    }

    private func finishCall(reason: String) {
        setupTrace?.finish("failed:\(reason)")
        turn?.finish("call_ended")
        probeRun?.finish("call_ended")
        setupTrace = nil
        turn = nil
        probeRun = nil
        provider = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        #if DEBUG
        if let last = transcript.last { log("transcript \(last.speaker): \(last.text)") }
        log("server_events " + serverEventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        #endif
        let callMs = Double(DispatchTime.now().uptimeNanoseconds - callStarted) / 1e6
        log(String(format: "ended reason=%@ callMs=%.0f usageSeconds=%.1f", reason, callMs, usageSeconds ?? -1))
        phase = .idle
        timeline = pendingTimeline
        if OpenAILiveVoiceProvider.useHotAudio {
            HotAudioDevice.shared.endBuffering()
            HotAudioDevice.shared.backgroundStart = false
            HotAudioDevice.shared.chimeOnFirstCapture = false
        }
        if error == nil { status = "Call ended" }
        #if DEBUG
        let noPrepare = ProcessInfo.processInfo.arguments.contains("--no-prepare")
        #else
        let noPrepare = false
        #endif
        if !noPrepare { prepareNext() }
        if WakeController.shared.handingOver {
            // Ended before its microphone took over: the listener never stopped.
            WakeController.shared.cancelHandover()
            resumeWakeListener = false
        }
        if resumeWakeListener {
            resumeWakeListener = false
            WakeController.shared.start()
        }
        if let spotify = pendingSpotify {
            pendingSpotify = nil
            SpotifyPlayer.open(spotify)
        }
        #if DEBUG
        // --calls N: repeat the call in the same process to measure the warm path.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--calls"), index + 1 < args.count, let total = Int(args[index + 1]) {
            completedCalls += 1
            if completedCalls < total {
                let probe = args.firstIndex(of: "--talk").flatMap { args.indices.contains($0 + 1) ? Probe(rawValue: args[$0 + 1]) : nil }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    self.start(trigger: "repeat", probe: probe)
                }
            }
        }
        #endif
    }
    private var completedCalls = 0

    private func fail(_ message: String) {
        log("failed \(message)")
        error = localListening ? message + " Anything you said was not sent." : message
        status = "Not connected"
        timeline = pendingTimeline
        setupTrace?.finish("failed", fields: ["error": message])
        setupTrace = nil
        if provider == nil {
            phase = .idle
            if WakeController.shared.handingOver {
                WakeController.shared.cancelHandover()
                resumeWakeListener = false
            }
            if resumeWakeListener {
                resumeWakeListener = false
                WakeController.shared.start()
            }
        }
    }

    private func observeInterruptions() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            else { return }
            MainActor.assumeIsolated { self?.stop(reason: "interrupted") }
        }
    }

    private func record(_ name: String, at time: UInt64 = DispatchTime.now().uptimeNanoseconds, fields: [String: Any] = [:]) {
        setupTrace?.mark(name, at: time, fields: fields, once: true)
        let ms = Double(time >= setupOrigin ? time - setupOrigin : 0) / 1e6
        if !pendingTimeline.contains(where: { $0.name == name }) { pendingTimeline.append(TimelineRow(name: name, ms: ms)) }
        if phase != .connecting { timeline = pendingTimeline }
        let details = fields.isEmpty ? "" : " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log(String(format: "mark %@ %.1fms", name, ms) + details)
    }

    /// For app-level events (launch, scene changes, intents) that happen outside a call.
    nonisolated static func appLog(_ message: String) {
        // Uptime since process start, so iOS's share (launch, foregrounding) is visible.
        let ms = Double(DispatchTime.now().uptimeNanoseconds - LatencyTrace.processStart) / 1e6
        let line = String(format: "@%.0fms ", ms) + message
        Task { @MainActor in shared.log(line) }
    }

    private func log(_ message: String) {
        print("VOICE \(message)")
        #if DEBUG
        // Test scripts read this file instead of attaching a console, which can stall the app.
        let line = "VOICE \(message)\n"
        Self.consoleQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: Self.consoleURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: Self.consoleURL)
            }
        }
        #endif
    }

    #if DEBUG
    static let consoleURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice-console.log")
    private static let consoleQueue = DispatchQueue(label: "voice.console", qos: .utility)
    #endif

    /// How long the process had existed when the trigger happened (shows cold launches).
    static func processAgeMs(at origin: UInt64) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        let now = Date().timeIntervalSince1970
        let triggerAgo = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1e9
        return (now - triggerAgo - started) * 1000
    }
}

/// One request → spoken answer. A delegated request (web search) usually gets a short spoken
/// filler first, so the trace stays open until the backend finishes and its answer is heard.
final class Exchange {
    let trace: LatencyTrace
    let source: String
    var responseMs: Double?
    private(set) var heardReply = false
    private(set) var delegated = false
    private var delegationPending = false
    private var backendDone = false
    private var answerTranscript = false
    private var finished = false
    private var order: [(String, Double)] = []

    init(source: String, origin: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.source = source
        trace = LatencyTrace(source: source, origin: origin)
    }

    /// Compact "name@ms" list for the console.
    var milestones: String { order.map { "\($0.0)@\(Int($0.1))" }.joined(separator: " ") }

    private func mark(_ name: String, at time: UInt64, fields: [String: Any] = [:]) {
        guard !order.contains(where: { $0.0 == name }) else { return }
        trace.mark(name, at: time, fields: fields, once: true)
        order.append((name, Double(time >= trace.origin ? time - trace.origin : 0) / 1e6))
    }

    func delegationCreated(at time: UInt64, fields: [String: Any]) {
        delegated = true
        delegationPending = true
        mark("delegation_created", at: time, fields: fields)
    }

    func backend(_ type: String, at time: UInt64) {
        mark("backend:\(type)", at: time)
        if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
            delegationPending = false
            backendDone = true
        }
    }

    func outputTranscript(at time: UInt64, fields: [String: Any]) {
        mark("first_reply_transcript", at: time, fields: fields)
        if backendDone, !answerTranscript {
            answerTranscript = true
            mark("answer_transcript", at: time)
        }
    }

    /// Returns true when the exchange is complete.
    func audioStarted(at time: UInt64) -> Bool {
        if !heardReply {
            heardReply = true
            mark("reply_audio_start", at: time)
        }
        if backendDone {
            mark("answer_audio_start", at: time)
            return true
        }
        return !delegationPending
    }

    /// The answer can follow the filler without a pause; then it ends when the speech does.
    func audioStopped(at time: UInt64) -> Bool { backendDone && answerTranscript }

    func finish(_ outcome: String, fields: [String: Any] = [:]) {
        guard !finished else { return }
        finished = true
        trace.finish(outcome, fields: fields)
    }
}

/// Records the first display refresh after a trigger, i.e. roughly the first frame the user
/// can see. Display links do not fire while the app is in the background.
@MainActor
final class FirstFrameProbe: NSObject {
    static let shared = FirstFrameProbe()
    private var link: CADisplayLink?
    private var completion: ((UInt64) -> Void)?

    func arm(_ completion: @escaping (UInt64) -> Void) {
        link?.invalidate()
        self.completion = completion
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard UIApplication.shared.applicationState != .background else { return }
        let time = DispatchTime.now().uptimeNanoseconds
        link?.invalidate()
        link = nil
        completion?(time)
        completion = nil
    }
}
