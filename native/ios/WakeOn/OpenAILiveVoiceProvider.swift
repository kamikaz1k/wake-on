import AVFoundation
import Foundation
import WebRTC

/// Settings for one GPT-Live session. Defaults favour low latency.
struct LiveVoiceConfig {
    var endpoint = URL(string: "https://api.openai.com/v1/live/sessions")!
    var model = "gpt-live-1.1"
    var voice = "marin"
    /// Voices offered in settings, checked against gpt-live-1 and gpt-live-1.1 on the phone (see voiceKey).
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static let voiceKey = "voice.name"
    static var chosenVoice: String {
        let saved = UserDefaults.standard.string(forKey: voiceKey) ?? "marin"
        return voices.contains(saved) ? saved : "marin"
    }
    var instructions = """
    You are \(Agent.name), a voice assistant the user starts from their iPhone. Answer in one or two short \
    spoken sentences unless they ask for more. Start speaking right away. Always reply when the user \
    stops talking, even if they only counted, tested the microphone or made a statement: acknowledge \
    it briefly. When a question needs \
    current or factual information you are unsure of, delegate it so it can be searched on the web. \
    Delegate requests to play music too; they open in Spotify and the call ends. \
    Delegate requests for directions or to open a place in Maps too; they open in Google Maps and \
    the call ends. \
    Delegate requests to see, show, chart, draw or visualize something: it appears on the user's \
    screen and the call goes on. \
    You cannot play, pause or open anything yourself: only a delegated request does it, so always \
    delegate those requests, and never say you started, played or paused something otherwise. \
    While it is being looked up, say at most three words such as "One moment", then stop and wait, \
    so the answer can be spoken as soon as it arrives. \
    When the user is clearly finished (for example "that's all", "thanks, bye", "okay, I'm done", or \
    "no" to "Anything else?"), reply with only a brief send-off that ends with the word "Bye", such as \
    "Okay, bye." The call ends by itself after that. End a reply with "Bye" only when the conversation \
    is over; never for a pause, a thank-you in the middle of a conversation, or a new question. \
    When you have fully answered and nothing is left open (you asked the user nothing and are not \
    waiting on a lookup), end that reply with "Anything else?". If the user then says no or that's \
    all, send them off with "Bye" as above. If you are told the user has gone quiet, check in with \
    one short question, such as "Anything else?"
    """
    var delegationModel = "gpt-6.1-terra"
    var delegationInstructions = """
    You answer questions for a voice assistant. Use web search for anything time-sensitive. \
    Reply with the answer only, in plain sentences suitable for reading aloud, under 60 words.
    """
    var delegationReasoningEffort: String? = "low"
    var delegation = true
    var webSearch = true
    /// What was said earlier in a resumed chat, oldest first (empty for a new chat).
    var history: [ChatLog.Line] = []
    /// The play_spotify tool (see SpotifyPlayer).
    var spotify = true
    /// The play_youtube tool (see YouTubePlayer).
    var youtube = true
    /// The control_media tool: pause, resume, skip whatever is playing (see MediaControl).
    var mediaControl = MediaControl.available
    /// The set_volume tool (see VolumeControl).
    var volume = true
    /// The save_note tool: notes in the user's Obsidian vault (see ObsidianNotes). Only once a
    /// vault is picked in Settings.
    var notes = false
    /// The open_map tool: directions or a place in Google Maps (see MapsOpener).
    var maps = true
    /// The get_location tool: where the user is, after iOS's permission (see CurrentLocation).
    var location = true
    /// The show_visual tool: an HTML page shown in the chat (see ShowVisual).
    var visuals = true
    /// The browser tool: an in-app browser Pixie can drive (see BrowserTool).
    var browser = true
    /// The remember and recall tools (see Memory).
    var memoryTools = true
    /// What Pixie remembers, for both models' instructions (`Memory.callText`).
    var memory: String?
    /// Host candidates are enough: OpenAI's media servers are publicly reachable.
    var iceGatheringTimeout: Duration = .seconds(3)
    /// Send the offer once no new candidate has appeared for this long.
    var iceQuietPeriod: Duration = .milliseconds(25)
    var statsInterval: Duration = .milliseconds(50)

    /// The backend's instructions; with `screen`, a last line saying whether the user can see it.
    func backendInstructions(screen: ScreenPresence? = nil, browser browserLine: String? = nil) -> String {
        var text = delegationInstructions
        if spotify { text += " " + SpotifyPlayer.delegationInstructions }
        if youtube { text += " " + YouTubePlayer.delegationInstructions }
        if mediaControl { text += " " + MediaControl.delegationInstructions }
        if volume { text += " " + VolumeControl.delegationInstructions }
        if notes { text += " " + ObsidianNotes.delegationInstructions }
        if location { text += " " + CurrentLocation.delegationInstructions }
        if maps { text += " " + MapsOpener.delegationInstructions }
        if visuals { text += " " + ShowVisual.delegationInstructions }
        if browser { text += " " + BrowserTool.delegationInstructions }
        if memoryTools { text += " " + Memory.delegationInstructions }
        if visuals || maps || browser {
            text += " " + ScreenPresence.backendGuidance
            if let screen { text += "\n" + screen.backendLine }
        }
        if browser, let browserLine { text += "\n" + browserLine }
        if let memory { text += "\n\n" + memory }
        if let earlier = Self.historyNote(history) { text += "\n\n" + earlier }
        return text
    }

    /// Mid-call update for the backend when the screen comes into view or goes away. The
    /// voice model is told with `session.thinking.append` (see `ScreenPresence.thinking`).
    func screenUpdate(_ screen: ScreenPresence, browser: String? = nil) -> [String: Any] {
        ["type": "session.update",
         "session": ["delegation": ["type": "responses",
                                    "responses": ["instructions": backendInstructions(screen: screen, browser: browser)]]]]
    }

    /// The earlier conversation for a resumed chat, newest lines kept when it's long.
    static func historyNote(_ lines: [ChatLog.Line]) -> String? {
        guard !lines.isEmpty else { return nil }
        // Newest lines first, up to the token limit (see ChatTokens).
        var kept: [String] = []
        var tokens = 0
        for line in lines.reversed() {
            let text = ChatTokens.line(line)
            if tokens + ChatTokens.estimate(text) > ChatTokens.limit, !kept.isEmpty { break }
            kept.insert(text, at: 0)
            tokens += ChatTokens.estimate(text)
        }
        let cut = kept.count < lines.count ? "(Earlier lines left out.)\n" : ""
        return "This call resumes an earlier conversation with the same user. What was said so far:\n"
            + cut + kept.joined(separator: "\n")
            + "\nCarry on from there: don't greet or introduce yourself again, and use what was said "
            + "when the user refers back to it."
    }

    func requestBody(sdp: String) -> [String: Any] {
        // The screen line comes once the call is up: a prepared offer is built before the
        // trigger, when the app's state says nothing about the call.
        var responses: [String: Any] = ["model": delegationModel, "instructions": backendInstructions()]
        var tools: [[String: Any]] = []
        if webSearch { tools.append(["type": "web_search"]) }
        if spotify { tools.append(SpotifyPlayer.tool) }
        if youtube { tools.append(YouTubePlayer.tool) }
        if mediaControl { tools.append(MediaControl.tool) }
        if volume { tools.append(VolumeControl.tool) }
        if notes { tools.append(ObsidianNotes.tool) }
        if location { tools.append(CurrentLocation.tool) }
        if maps { tools.append(MapsOpener.tool) }
        if visuals { tools.append(ShowVisual.tool) }
        if browser { tools.append(BrowserTool.tool) }
        if memoryTools { tools += Memory.tools }
        if !tools.isEmpty {
            responses["tools"] = tools
            responses["tool_choice"] = "auto"
        }
        if let effort = delegationReasoningEffort { responses["reasoning"] = ["effort": effort] }
        var voiceInstructions = instructions
        if mediaControl { voiceInstructions += " " + MediaControl.voiceInstructions }
        if browser { voiceInstructions += " " + BrowserTool.voiceInstructions }
        if memoryTools { voiceInstructions += " " + Memory.voiceInstructions }
        if let memory { voiceInstructions += "\n\n" + memory }
        if let earlier = Self.historyNote(history) { voiceInstructions += "\n\n" + earlier }
        var session: [String: Any] = ["model": model, "instructions": voiceInstructions,
                                      "audio": ["output": ["voice": voice]]]
        if delegation { session["delegation"] = ["type": "responses", "responses": responses] }
        return ["session": session, "transport": ["type": "webrtc", "sdp": sdp]]
    }
}

/// Cumulative WebRTC statistics sampled every `statsInterval`.
struct LiveVoiceStats {
    var time: Double
    var microphoneEnergy: Double?
    var microphoneDuration: Double?
    var remoteEnergy: Double?
    var remoteDuration: Double?
    var packetsReceived = 0
    var packetsSent = 0
    var roundTripMs: Double?
    /// Mean time received audio waits in the jitter buffer before playout.
    var jitterBufferMs: Double?
    var concealedSamples = 0
    var totalSamplesReceived = 0
}

enum LiveVoiceEvent {
    /// A setup milestone with the uptime (ns) it happened at.
    case milestone(String, UInt64, [String: Any])
    case server([String: Any], UInt64)
    /// An event the app sent on the data channel.
    case sent([String: Any], UInt64)
    case stats(LiveVoiceStats)
    case ended(String)
}

/// GPT-Live over WebRTC, straight from the phone to OpenAI. No relay server.
@MainActor
final class OpenAILiveVoiceProvider: NSObject {
    /// Use the app's own pre-armed audio engine (`HotAudioDevice`) instead of WebRTC's
    /// built-in iOS audio. Must be decided before the factory is first used.
    nonisolated(unsafe) static var useHotAudio = true

    nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        guard useHotAudio else { return RTCPeerConnectionFactory() }
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory(),
                                        audioDevice: HotAudioDevice.shared)
    }()

    /// Reused so a second call can skip DNS, TCP and TLS.
    nonisolated private static let http: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    var onEvent: ((LiveVoiceEvent) -> Void)?
    private(set) var sessionID: String?
    let config: LiveVoiceConfig
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var track: RTCAudioTrack?
    private var statsTask: Task<Void, Never>?
    private var closed = false
    /// Only a started call owns the audio; closing an unused prepared call must not touch it.
    private var started = false
    private var sentRemoteTrack = false
    private var sentMicrophone = false

    private lazy var audioObserver = AudioObserver { [weak self] name in self?.report(name) }

    init(config: LiveVoiceConfig = LiveVoiceConfig()) {
        self.config = config
    }

    /// Opens a TLS connection ahead of time to where the next call is set up (OpenAI, or the
    /// Pixie server with an invite code). Costs nothing.
    static func prewarm() {
        _ = factory
        let openAI = URL(string: "https://api.openai.com/v1/live/sessions")!
        let target = OpenAIKeyStore.load().flatMap { try? LobbyServer.endpoint(for: $0.key, openAI: openAI) } ?? openAI
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        http.dataTask(with: request).resume()
    }

    /// Builds the peer connection, offer and ICE candidates. Costs nothing on OpenAI's side and
    /// does not start the microphone, so it can run before the user asks for a call.
    func prepare() async throws {
        if preparedSDP != nil { return }
        // A trigger can arrive while a prepare is still running: join it, never build twice.
        if let prepareTask { return try await prepareTask.value }
        let task = Task { try await self.buildOffer() }
        prepareTask = task
        try await task.value
    }
    private var prepareTask: Task<Void, Error>?

    private func buildOffer() async throws {
        let begin = DispatchTime.now().uptimeNanoseconds
        await Self.warmup.wait()
        emit("webrtc_warm", fields: ["warmupMs": Self.warmupMs])
        let hot = Self.useHotAudio
        let audio = RTCAudioSession.sharedInstance()
        if !hot {
            audio.add(audioObserver)
            audio.useManualAudio = true
            audio.isAudioEnabled = false
        }
        let session = RTCAudioSessionConfiguration.webRTC()
        session.category = AVAudioSession.Category.playAndRecord.rawValue
        session.mode = AVAudioSession.Mode.voiceChat.rawValue
        session.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        // WebRTC reapplies its global configuration when the audio unit starts.
        if !hot { RTCAudioSessionConfiguration.setWebRTC(session) }

        let rtc = RTCConfiguration()
        rtc.sdpSemantics = .unifiedPlan
        rtc.bundlePolicy = .maxBundle
        rtc.rtcpMuxPolicy = .require
        rtc.continualGatheringPolicy = .gatherOnce
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: rtc, constraints: none, delegate: self) else {
            throw VoiceError.message("WebRTC could not create a peer connection.")
        }
        self.peer = peer
        let source = Self.factory.audioSource(with: none)
        let track = Self.factory.audioTrack(with: source, trackId: "microphone")
        self.track = track
        peer.add(track, streamIds: ["voice"])
        let dataConfig = RTCDataChannelConfiguration()
        dataConfig.isOrdered = true
        guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: dataConfig) else {
            throw VoiceError.message("WebRTC could not create the events channel.")
        }
        channel.delegate = self
        self.channel = channel
        emit("peer_created")

        let offerConstraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"],
                                                   optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: offerConstraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceError.message("No SDP offer.")) }
            }
        }
        emit("offer_created")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        emit("local_description_set")
        // "Complete" takes ~100 ms after the last useful candidate; send once candidates stop arriving.
        var lastCount = 0
        var lastChange = ContinuousClock.now
        let gathered = try await waitUntil(timeout: config.iceGatheringTimeout) {
            if peer.iceGatheringState == .complete { return true }
            let count = (peer.localDescription?.sdp.components(separatedBy: "a=candidate:").count ?? 1) - 1
            if count != lastCount { lastCount = count; lastChange = .now }
            return count > 0 && ContinuousClock.now - lastChange >= config.iceQuietPeriod
        }
        guard let sdp = peer.localDescription?.sdp, !closed else { throw VoiceError.message("Call ended during setup.") }
        let candidates = sdp.components(separatedBy: "a=candidate:").count - 1
        emit("ice_gathering_done", fields: ["complete": peer.iceGatheringState == .complete, "beforeTimeout": gathered,
                                            "candidates": candidates, "sdpBytes": sdp.utf8.count])
        guard candidates > 0 else { throw VoiceError.message("No network path found for the call.") }
        audioConfig = session
        preparedSDP = sdp
        preparedAt = DispatchTime.now().uptimeNanoseconds
        prepareMs = Double(preparedAt! - begin) / 1e6
        preparedCandidates = candidates
    }

    /// Sends the prepared offer right now, synchronously, if there is one. Returns when it was sent.
    func sendPreparedOffer(apiKey: String) -> UInt64? {
        guard let sdp = preparedSDP, !closed, pendingRequest == nil,
              let request = try? makeRequest(sdp: sdp, apiKey: apiKey) else { return nil }
        started = true
        pendingRequest = Task.detached { try await Self.send(request) }
        let sent = DispatchTime.now().uptimeNanoseconds
        requestSentAt = sent
        return sent
    }
    private var pendingRequest: Task<SessionResult, Error>?
    private(set) var requestSentAt: UInt64?

    /// Prepared ahead of the trigger: the offer to send.
    private(set) var preparedSDP: String?
    private(set) var preparedAt: UInt64?
    private var prepareMs: Double = 0
    private var preparedCandidates = 0
    private var audioConfig: RTCAudioSessionConfiguration?

    func start(apiKey: String) async throws {
        started = true
        let hot = Self.useHotAudio
        if let preparedAt, preparedSDP != nil {
            emit("offer_reused", fields: ["ageMs": Double(DispatchTime.now().uptimeNanoseconds - preparedAt) / 1e6,
                                         "prepareMs": prepareMs, "candidates": preparedCandidates])
        } else {
            try await prepare()
        }
        guard let sdp = preparedSDP, let session = audioConfig, let peer, !closed else {
            throw VoiceError.message("Call ended during setup.")
        }

        // Send the offer now and bring up audio on another thread: audio activation (~100 ms)
        // overlaps the server creating the session and applying its answer.
        let pending: Task<SessionResult, Error>
        if let pendingRequest {
            pending = pendingRequest
        } else {
            let request = try makeRequest(sdp: sdp, apiKey: apiKey)
            emit("http_request_begin")
            pending = Task.detached { try await Self.send(request) }
            pendingRequest = pending
        }
        // With the hot device the controller armed audio at the trigger; nothing to do here.
        let audioReady: Task<AudioTiming?, Error> = Task.detached(priority: .userInitiated) {
            hot ? nil : try Self.activateAudio(session)
        }
        let result: SessionResult
        do {
            result = try await pending.value
        } catch {
            _ = try? await audioReady.value
            throw error
        }
        emit("http_response", at: result.finished, fields: result.fields)
        guard (200..<300).contains(result.status) else {
            if LobbyServer.isInviteCode(apiKey),
               let problem = LobbyServer.problem(status: result.status, code: result.errorCode) {
                // Only the saved code is marked (a debug --invite code isn't saved).
                if problem.needsNewCode, OpenAIKeyStore.load()?.key == apiKey {
                    UserDefaults.standard.set(true, forKey: LobbyServer.needsNewCodeKey)
                }
                throw VoiceError.message(problem.message)
            }
            throw VoiceError.message("OpenAI refused the session (\(result.status)): \(result.errorMessage)")
        }
        guard let answer = result.answer else { throw VoiceError.message("OpenAI returned no SDP answer.") }
        sessionID = result.sessionID
        guard !closed else { throw VoiceError.message("Call ended during setup.") }
        emit("remote_description_begin")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        emit("remote_description_set")
        if let audioTiming = try await audioReady.value {
            emit("audio_session_begin", at: audioTiming.begin)
            emit("audio_session_active", at: audioTiming.active, fields: audioTiming.fields)
            emit("audio_unit_enabled", at: audioTiming.enabled)
        }
        startStats()
    }

    struct AudioTiming: @unchecked Sendable {
        var begin: UInt64
        var active: UInt64
        var enabled: UInt64
        var fields: [String: Any]
    }

    /// Activates the audio session and starts WebRTC's audio unit so it is warm when media flows.
    /// Thread-safe: RTCAudioSession serialises configuration behind its lock.
    nonisolated private static func activateAudio(_ configuration: RTCAudioSessionConfiguration) throws -> AudioTiming {
        let begin = DispatchTime.now().uptimeNanoseconds
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        try audio.setConfiguration(configuration, active: true)
        let active = DispatchTime.now().uptimeNanoseconds
        let avSession = AVAudioSession.sharedInstance()
        let fields: [String: Any] = ["ioBufferMs": avSession.ioBufferDuration * 1000,
                                     "inputLatencyMs": avSession.inputLatency * 1000,
                                     "outputLatencyMs": avSession.outputLatency * 1000,
                                     "sampleRate": avSession.sampleRate,
                                     "route": avSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")]
        audio.isAudioEnabled = true
        return AudioTiming(begin: begin, active: active, enabled: DispatchTime.now().uptimeNanoseconds, fields: fields)
    }

    /// Runs a throwaway local offer/answer so WebRTC's one-time setup (threads, DTLS, SCTP)
    /// is paid at launch, off the main thread, instead of during the first call.
    nonisolated static func prewarmMedia() {
        warmup.start()
    }

    /// A call waits for the warm-up instead of racing it inside WebRTC.
    nonisolated static let warmup = Warmup()
    final class Warmup: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func start() {
            lock.withLock {
                guard task == nil else { return }
                task = Task.detached(priority: .userInitiated) { await OpenAILiveVoiceProvider.runWarmup() }
            }
        }
        private func current() -> Task<Void, Never>? { lock.withLock { task } }
        func wait() async { await current()?.value }
    }

    nonisolated private static func runWarmup() async {
        do {
            let start = DispatchTime.now().uptimeNanoseconds
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let sink = SilentPeerDelegate()
            guard let caller = factory.peerConnection(with: config, constraints: none, delegate: sink),
                  let callee = factory.peerConnection(with: config, constraints: none, delegate: sink) else { return }
            defer { caller.close(); callee.close() }
            _ = caller.dataChannel(forLabel: "warm", configuration: RTCDataChannelConfiguration())
            if warmAudioEngine && !useHotAudio {
                // Manual audio keeps the warm-up from touching the microphone or the audio session.
                let audio = RTCAudioSession.sharedInstance()
                audio.useManualAudio = true
                audio.isAudioEnabled = false
                _ = caller.addTransceiver(of: .audio)
            }
            func describe(_ make: (@escaping (RTCSessionDescription?, Error?) -> Void) -> Void) async -> RTCSessionDescription? {
                await withCheckedContinuation { continuation in make { description, _ in continuation.resume(returning: description) } }
            }
            func apply(_ make: (@escaping (Error?) -> Void) -> Void) async {
                await withCheckedContinuation { continuation in make { _ in continuation.resume() } }
            }
            guard let offer = await describe({ caller.offer(for: none, completionHandler: $0) }) else { return }
            await apply { caller.setLocalDescription(offer, completionHandler: $0) }
            await apply { callee.setRemoteDescription(offer, completionHandler: $0) }
            guard let answer = await describe({ callee.answer(for: none, completionHandler: $0) }) else { return }
            await apply { callee.setLocalDescription(answer, completionHandler: $0) }
            await apply { caller.setRemoteDescription(answer, completionHandler: $0) }
            warmupMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
    }
    nonisolated(unsafe) static var warmupMs: Double = -1
    /// Also warm the audio engine (codecs, echo canceller). Calls wait for the warm-up, never race it.
    nonisolated(unsafe) static var warmAudioEngine = true

    func setMuted(_ muted: Bool) { track?.isEnabled = !muted }

    func send(_ event: [String: Any]) {
        guard let channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        onEvent?(.sent(event, DispatchTime.now().uptimeNanoseconds))
    }

    /// Asks the server to finish the session; `session.closed` follows on the data channel.
    func requestClose() { send(["type": "session.close"]) }

    /// Tells both models whether the user can see the screen (see `ScreenPresence`).
    /// `notes`: what the voice model should hear about (the screen and/or the browser changed).
    func sendScreen(_ screen: ScreenPresence, browser: String?, notes: [String]) {
        send(config.screenUpdate(screen, browser: browser))
        if !notes.isEmpty {
            send(["type": "session.thinking.append", "delegation_id": NSNull(), "content": notes.joined(separator: " ")])
        }
    }

    /// Gives the Live model something to say to the user now (`session.commentary.append`).
    func sendCommentary(_ content: String) {
        send(["type": "session.commentary.append", "delegation_id": NSNull(), "content": content])
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        statsTask?.cancel()
        track?.isEnabled = false
        channel?.close()
        peer?.close()
        channel = nil
        peer = nil
        track = nil
        if !started {
            // An unused prepared call: nothing else to release.
        } else if Self.useHotAudio {
            HotAudioDevice.shared.disarm()
        } else {
            let audio = RTCAudioSession.sharedInstance()
            audio.remove(audioObserver)
            audio.lockForConfiguration()
            audio.isAudioEnabled = false
            try? audio.setActive(false)
            audio.unlockForConfiguration()
        }
        onEvent?(.ended(reason))
    }

    // MARK: - Signalling

    private func makeRequest(sdp: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: try LobbyServer.endpoint(for: apiKey, openAI: config.endpoint))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The voice is read now, not when the call was prepared, so a change applies at once.
        var current = config
        current.voice = LiveVoiceConfig.chosenVoice
        request.httpBody = try JSONSerialization.data(withJSONObject: current.requestBody(sdp: sdp))
        return request
    }

    struct SessionResult: @unchecked Sendable {
        var status: Int
        var answer: String?
        var sessionID: String?
        var errorMessage: String
        var errorCode: String?
        var fields: [String: Any]
        var finished: UInt64
    }

    nonisolated private static func send(_ request: URLRequest) async throws -> SessionResult {
        let metrics = MetricsCollector()
        let (data, response) = try await http.data(for: request, delegate: metrics)
        let finished = DispatchTime.now().uptimeNanoseconds
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var fields = metrics.fields
        fields["status"] = status
        for header in ["x-request-id", "openai-processing-ms", "server-timing"] {
            if let value = http?.value(forHTTPHeaderField: header) { fields[header] = value }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errorCode = (json?["error"] as? [String: Any])?["code"] as? String
        let message = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        let answer = ((json?["transport"] as? [String: Any])?["sdp"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SessionResult(status: status, answer: answer,
                             sessionID: (json?["session"] as? [String: Any])?["id"] as? String,
                             errorMessage: message, errorCode: errorCode, fields: fields, finished: finished)
    }

    // MARK: - Statistics

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let peer = self.peer else { return }
                let stats = await withCheckedContinuation { (continuation: CheckedContinuation<LiveVoiceStats, Never>) in
                    peer.statistics { report in
                        continuation.resume(returning: Self.parse(report, at: uptimeSeconds()))
                    }
                }
                if self.closed { return }
                if !self.sentRemoteTrack, stats.packetsReceived > 0 {
                    self.sentRemoteTrack = true
                    self.emit("first_audio_packet_received")
                }
                if !self.sentMicrophone, stats.packetsSent > 0 {
                    // The microphone is captured and its audio is leaving the phone.
                    self.sentMicrophone = true
                    self.emit("first_microphone_packet_sent")
                }
                self.onEvent?(.stats(stats))
                try? await Task.sleep(for: self.sentMicrophone ? self.config.statsInterval : .milliseconds(10))
            }
        }
    }

    nonisolated static func parse(_ report: RTCStatisticsReport, at time: Double) -> LiveVoiceStats {
        var stats = LiveVoiceStats(time: time)
        for stat in report.statistics.values {
            let values = stat.values
            func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
            switch stat.type {
            case "media-source":
                guard (values["kind"] as? String) == "audio" else { continue }
                stats.microphoneEnergy = number("totalAudioEnergy")
                stats.microphoneDuration = number("totalSamplesDuration")
            case "inbound-rtp":
                guard (values["kind"] as? String) == "audio" else { continue }
                stats.remoteEnergy = number("totalAudioEnergy")
                stats.remoteDuration = number("totalSamplesDuration")
                stats.packetsReceived = Int(number("packetsReceived") ?? 0)
                stats.concealedSamples = Int(number("concealedSamples") ?? 0)
                stats.totalSamplesReceived = Int(number("totalSamplesReceived") ?? 0)
                if let delay = number("jitterBufferDelay"), let count = number("jitterBufferEmittedCount"), count > 0 {
                    stats.jitterBufferMs = delay / count * 1000
                }
            case "outbound-rtp":
                guard (values["kind"] as? String) == "audio" else { continue }
                stats.packetsSent = Int(number("packetsSent") ?? 0)
            case "candidate-pair":
                guard (values["nominated"] as? NSNumber)?.boolValue == true,
                      (values["state"] as? String) == "succeeded",
                      let rtt = number("currentRoundTripTime") else { continue }
                stats.roundTripMs = rtt * 1000
            default:
                continue
            }
        }
        return stats
    }

    // MARK: - Helpers

    private func emit(_ name: String, at time: UInt64 = DispatchTime.now().uptimeNanoseconds, fields: [String: Any] = [:]) {
        onEvent?(.milestone(name, time, fields))
    }

    /// Delegate callbacks capture the time on WebRTC's thread, before hopping to the main actor.
    nonisolated private func report(_ name: String, fields: [String: Any] = [:]) {
        let time = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor [weak self] in self?.emit(name, at: time, fields: fields) }
    }

    private func waitUntil(timeout: Duration, _ ready: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !ready() {
            if closed { throw VoiceError.message("Call ended during setup.") }
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

func uptimeSeconds(_ nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
    Double(nanoseconds) / 1e9
}

/// Collects DNS, connect, TLS and first-byte timings for the session request.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String: Any] = [:]
    var fields: [String: Any] { lock.lock(); defer { lock.unlock() }; return collected }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func ms(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        var result: [String: Any] = ["reusedConnection": transaction.isReusedConnection,
                                     "protocol": transaction.networkProtocolName ?? "unknown",
                                     "totalMs": metrics.taskInterval.duration * 1000]
        result["dnsMs"] = ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        result["connectMs"] = ms(transaction.connectStartDate, transaction.connectEndDate)
        result["tlsMs"] = ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        result["uploadMs"] = ms(transaction.requestStartDate, transaction.requestEndDate)
        result["serverWaitMs"] = ms(transaction.requestEndDate, transaction.responseStartDate)
        result["downloadMs"] = ms(transaction.responseStartDate, transaction.responseEndDate)
        lock.lock()
        collected = result.compactMapValues { $0 }
        lock.unlock()
    }
}

extension OpenAILiveVoiceProvider: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .checking: report("ice_checking")
        case .connected, .completed: report("ice_connected")
        case .failed, .disconnected, .closed:
            report("ice_\(newState == .failed ? "failed" : newState == .closed ? "closed" : "disconnected")")
            Task { @MainActor [weak self] in self?.close(reason: "network") }
        default: break
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .connected { report("peer_connected") }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                    streams mediaStreams: [RTCMediaStream]) {
        report("remote_track_added")
    }

    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: report("data_channel_open")
        case .closed:
            report("data_channel_closed")
            Task { @MainActor [weak self] in self?.close(reason: "data_channel_closed") }
        default: break
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let time = DispatchTime.now().uptimeNanoseconds
        guard let json = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
        Task { @MainActor [weak self] in self?.onEvent?(.server(json, time)) }
    }
}

private final class SilentPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Reports when WebRTC's audio unit actually starts (the hardware is capturing and playing).
private final class AudioObserver: NSObject, RTCAudioSessionDelegate {
    private let report: (String) -> Void
    init(report: @escaping (String) -> Void) { self.report = report }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) { report("audio_unit_started") }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) { report("audio_unit_stopped") }
    func audioSession(_ audioSession: RTCAudioSession, didChangeCanPlayOrRecord canPlayOrRecord: Bool) {
        if canPlayOrRecord { report("audio_can_play_or_record") }
    }
}
