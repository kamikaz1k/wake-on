import AVFoundation
import WebRTC

/// WebRTC's audio, supplied by an AVAudioEngine the app starts itself.
///
/// WebRTC's built-in iOS audio starts the voice-processing audio unit only when the
/// call's answer is applied: on an iPhone 17 Pro that is ~360 ms of session activation
/// plus ~390 ms of unit set-up, all on the critical path after the network. Here the
/// engine is *armed* as soon as the user asks for a call (or earlier), in parallel
/// with signalling. WebRTC's start/stop calls then only flip flags, because the
/// engine is already running.
///
/// Before WebRTC starts recording, microphone audio is discarded; before it starts
/// playout, the output is silent.
final class HotAudioDevice: NSObject, @unchecked Sendable {
    static let shared = HotAudioDevice()

    struct ArmTiming {
        var sessionMs: Double
        var engineMs: Double
        var alreadyArmed: Bool
        var inputRate: Double
        var outputRate: Double
        var ioBufferMs: Double
    }

    /// Serialises arming and engine changes. Never touched from the audio threads.
    private let queue = DispatchQueue(label: "voice.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var sink: AVAudioSinkNode?
    private var source: AVAudioSourceNode?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    // Read on the real-time audio threads. Aligned word loads and stores are atomic on arm64;
    // the blocks are set before the flags that enable them.
    private var delegate: RTCAudioDeviceDelegate?
    private var deliver: RTCAudioDeviceDeliverRecordedDataBlock?
    private var playout: RTCAudioDeviceGetPlayoutDataBlock?
    private var recording = false
    private var playing = false
    /// False while the app is in the background (set by the controller).
    var mayArm = true
    private var cachedIOBuffer: TimeInterval = 0.01
    private var cachedInputLatency: TimeInterval = 0
    private var cachedOutputLatency: TimeInterval = 0
    /// Int16 scratch for converting the microphone's Float32 frames (preallocated, max 4096 frames).
    private let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 4096)

    // Local buffering ("listen before connected"). The backlog is touched only on the
    // microphone thread; other threads request a reset through a flag.
    private let backlogCapacity = 480_000 // 10 s at 48 kHz
    private let backlog = UnsafeMutablePointer<Int16>.allocate(capacity: 480_000)
    private var backlogCount = 0
    private var backlogRead = 0
    private var backlogResetRequested = false
    private var capturedOnce = false
    /// Capture into the backlog while WebRTC is not sending yet.
    var buffering = false
    /// Set when the server is ready (`session.started`): the backlog is sent, then live audio.
    var released = false
    /// The backlog is sent at this multiple of real time until it has caught up.
    var catchUpSpeed = 4
    /// Microphone thread: the first captured frames (the user can talk from now on).
    var onFirstCapture: (() -> Void)?
    /// Debug: the raw backlog (Int16, 48 kHz mono), handed over once it has been sent.
    var onBacklogDump: ((Data) -> Void)?
    /// Microphone thread: the backlog has been sent; the stream is live. Argument: frames sent.
    var onBacklogDrained: ((Int) -> Void)?

    /// Starts a new call's local capture: empty backlog, hold audio until released.
    func beginBuffering() {
        backlogResetRequested = true
        released = false
        buffering = true
    }

    func endBuffering() {
        buffering = false
        released = false
        backlogResetRequested = true
    }

    /// Called on the audio thread the first time WebRTC is given microphone audio.
    var onFirstDelivery: (() -> Void)?
    private var deliveredOnce = false
    private var playedOnce = false
    /// Diagnostics: every call WebRTC makes into the device (any thread).
    var onTrace: ((String) -> Void)?
    private func trace(_ message: String) { onTrace?(message) }

    /// An engine exists for this session (it may be restarting after a configuration change).
    var isArmed: Bool { queue.sync { engine != nil } }
    private var isRunning: Bool { queue.sync { engine?.isRunning == true } }

    /// Activates the audio session and starts the engine. Safe to call repeatedly.
    func arm() throws -> ArmTiming {
        try queue.sync { try armLocked() }
    }

    /// Starts arming on the audio queue and returns at once.
    func armAsync(completion: @escaping (Result<ArmTiming, Error>) -> Void) {
        queue.async {
            completion(Result { try self.armLocked() })
        }
    }

    /// Stops the engine and releases the audio session so other apps can play again.
    /// Stops the microphone and releases the audio session, but keeps the built engine so the
    /// next call skips the ~120–140 ms voice-processing set-up.
    func disarm() {
        queue.sync {
            recording = false
            playing = false
            // Stop rather than pause: resuming from pause measured no faster on an iPhone 17 Pro
            // (session ~43 ms + start ~240 ms vs ~100 + ~180), and stopping frees the hardware.
            engine?.stop()
            enginePrepared = false
            if voiceProcessingOn {
                engine?.inputNode.isVoiceProcessingBypassed = true
            } else {
                // A plain-microphone fallback engine: rebuild with echo cancellation next time.
                teardownEngine()
            }
            sessionReady = false
            if !backgroundStart {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Voice processing (echo cancellation, noise suppression, AGC) is bypassed while only
    /// buffering: nothing is playing, so there is no echo, and its warm-up cannot swallow the
    /// first words. Turned on when the call goes live, before the assistant can speak.
    func enableVoiceProcessing() {
        queue.async {
            guard self.voiceProcessingOn, let engine = self.engine, engine.inputNode.isVoiceProcessingBypassed else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            engine.inputNode.isVoiceProcessingBypassed = false
            self.trace(String(format: "voice_processing_on ms=%.1f running=%@",
                              Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, engine.isRunning ? "yes" : "no"))
        }
    }

    /// True after this device activated the session in its voice-chat configuration.
    private var sessionReady = false

    /// Sets the voice-chat category and activates the session unless that is already done:
    /// repeating it costs ~90–105 ms even when nothing changes.
    /// Whether the current engine has voice processing (echo cancellation). A background start
    /// falls back to a plain microphone if iOS refuses voice processing there.
    private var voiceProcessingOn = true
    private var allowVoiceProcessing = true

    /// Wake-word call started in the background: a shared session (iOS refuses to activate an
    /// exclusive one from the background) that stays active after the call, so the listener can
    /// take the running session back without a fresh start.
    var backgroundStart = false

    private func activateSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if backgroundStart {
            // iOS refuses voice-chat (exclusive) configuration from the background ('!int').
            // The listener's shared session is still active: start the engine inside it.
            trace("session_kept category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue)")
            sessionReady = true
            return
        }
        if sessionReady, session.category == .playAndRecord, session.mode == .voiceChat { return }
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if backgroundStart { options.insert(.mixWithOthers) }
        trace("session_configure backgroundStart=\(backgroundStart) wasActiveCategory=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        sessionReady = true
    }

    /// The kept engine has been re-prepared for the current session (cleared when stopped).
    private var enginePrepared = false

    /// Reconnects the microphone if its format changed, then prepares the engine.
    private func prepareKeptEngine() {
        guard let engine, let sink else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        if current != pendingInputFormat, current.sampleRate > 0 {
            engine.disconnectNodeInput(sink)
            engine.connect(engine.inputNode, to: sink, format: current)
            pendingInputFormat = current
        }
        engine.prepare()
        enginePrepared = true
    }

    /// Builds the voice-processing engine and its graph without starting it. Nothing here
    /// records audio, so it can run while the app is still in the background.
    private func buildLocked() throws -> (sessionMs: Double, buildMs: Double, sessionActive: Bool) {
        let session = AVAudioSession.sharedInstance()
        if engine != nil {
            // Kept from an earlier call: bring the session back and re-prepare the engine now,
            // so starting it later is all that is left.
            let start = DispatchTime.now().uptimeNanoseconds
            let active = (try? activateSessionIfNeeded()) != nil
            let sessionDone = DispatchTime.now().uptimeNanoseconds
            if active { prepareKeptEngine() }
            return (Double(sessionDone - start) / 1e6, Double(DispatchTime.now().uptimeNanoseconds - sessionDone) / 1e6, active)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var active = true
        do { try activateSessionIfNeeded() } catch {
            active = false
            trace("session_activation_deferred \(error.localizedDescription)")
        }
        let sessionDone = DispatchTime.now().uptimeNanoseconds

        let engine = AVAudioEngine()
        // Enable voice processing (echo cancellation) right after creation, via the output
        // node so the input node is not created early; later changes are crash-prone.
        if allowVoiceProcessing { try engine.outputNode.setVoiceProcessingEnabled(true) }
        voiceProcessingOn = allowVoiceProcessing
        let input = engine.inputNode
        if voiceProcessingOn { input.isVoiceProcessingBypassed = true }
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw VoiceError.message("No microphone input is available.")
        }
        let speakerFormat = engine.outputNode.outputFormat(forBus: 0)
        let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: speakerFormat.sampleRate,
                                       channels: 1, interleaved: true)!

        let sink = AVAudioSinkNode { [unowned self] timestamp, frames, buffers in
            self.deliverMicrophone(timestamp: timestamp, frames: frames, buffers: buffers)
        }
        let source = AVAudioSourceNode(format: playFormat) { [unowned self] isSilence, timestamp, frames, output in
            self.renderPlayout(isSilence: isSilence, timestamp: timestamp, frames: frames, output: output)
        }
        engine.attach(sink)
        engine.attach(source)
        engine.connect(input, to: sink, format: micFormat)
        engine.connect(source, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        enginePrepared = true
        self.engine = engine
        self.sink = sink
        self.source = source
        pendingInputFormat = micFormat
        pendingOutputFormat = playFormat
        observe(engine)
        let built = DispatchTime.now().uptimeNanoseconds
        return (Double(sessionDone - start) / 1e6, Double(built - sessionDone) / 1e6, active)
    }
    private var pendingInputFormat: AVAudioFormat?
    private var pendingOutputFormat: AVAudioFormat?

    /// Builds the engine now (if needed) without starting the microphone.
    func prebuildAsync(completion: @escaping (Result<(sessionMs: Double, buildMs: Double, sessionActive: Bool), Error>) -> Void) {
        queue.async { completion(Result { try self.buildLocked() }) }
    }

    private func armLocked() throws -> ArmTiming {
        let session = AVAudioSession.sharedInstance()
        if let engine, engine.isRunning {
            return ArmTiming(sessionMs: 0, engineMs: 0, alreadyArmed: true,
                             inputRate: inputFormat?.sampleRate ?? 0, outputRate: outputFormat?.sampleRate ?? 0,
                             ioBufferMs: session.ioBufferDuration * 1000)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let prebuilt = engine != nil
        var sessionDone = start
        do {
            sessionDone = try buildAndStart(prebuilt: prebuilt)
        } catch where backgroundStart && voiceProcessingOn {
            // Experiment: echo cancellation may be refused in the background; try a plain microphone.
            trace("voice_processing_start_failed error=\((error as NSError).domain):\((error as NSError).code) prebuilt=\(prebuilt)")
            teardownEngine()
            allowVoiceProcessing = false
            defer { allowVoiceProcessing = true }
            sessionDone = try buildAndStart(prebuilt: false)
        }
        guard let engine, let micFormat = pendingInputFormat, let playFormat = pendingOutputFormat else {
            throw VoiceError.message("Audio engine was not built.")
        }
        let engineDone = DispatchTime.now().uptimeNanoseconds
        trace("engine_running voiceProcessing=\(voiceProcessingOn) backgroundStart=\(backgroundStart)")
        trace("engine_started running=\(engine.isRunning) prebuilt=\(prebuilt)")

        let previousInput = inputFormat?.sampleRate ?? 48_000
        let previousOutput = outputFormat?.sampleRate ?? 48_000
        let previousBuffer = cachedIOBuffer
        cachedIOBuffer = session.ioBufferDuration
        cachedInputLatency = session.inputLatency
        cachedOutputLatency = session.outputLatency
        inputFormat = micFormat
        outputFormat = playFormat
        // WebRTC may already be attached (re-arm after an interruption): tell it about new formats.
        if let delegate, previousInput != micFormat.sampleRate || previousOutput != playFormat.sampleRate
            || abs(previousBuffer - cachedIOBuffer) > 0.000_5 {
            delegate.dispatchAsync {
                delegate.notifyAudioInputParametersChange()
                delegate.notifyAudioOutputParametersChange()
            }
        }
        return ArmTiming(sessionMs: Double(sessionDone - start) / 1e6,
                         engineMs: Double(engineDone - sessionDone) / 1e6,
                         alreadyArmed: false, inputRate: micFormat.sampleRate,
                         outputRate: playFormat.sampleRate, ioBufferMs: session.ioBufferDuration * 1000)
    }

    private var observers: [NSObjectProtocol] = []
    private func observe(_ engine: AVAudioEngine) {
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
                self?.trace("engine_configuration_change running=\(engine?.isRunning ?? false)")
                self?.queue.async { self?.restartLocked(reason: "configuration_change") }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                self?.trace("route_change reason=\(reason) running=\(self?.engine?.isRunning ?? false)")
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 9
                self?.trace("interruption type=\(type)")
                self?.queue.async { self?.sessionReady = false }
            },
        ]
    }

    /// Builds (or re-prepares) the engine and starts it. Returns when the session step finished.
    private func buildAndStart(prebuilt: Bool) throws -> UInt64 {
        if prebuilt {
            // A kept engine: the session may have been changed in between (wake listener).
            try activateSessionIfNeeded()
            if !enginePrepared { prepareKeptEngine() }
        } else {
            _ = try buildLocked()
        }
        let sessionDone = DispatchTime.now().uptimeNanoseconds
        guard let engine else { throw VoiceError.message("Audio engine was not built.") }
        if !engine.isRunning { try engine.start() }
        return sessionDone
    }

    /// Destroys the engine so the next arm builds a fresh one.
    private func teardownEngine() {
        engine?.stop()
        if let sink { engine?.detach(sink) }
        if let source { engine?.detach(source) }
        engine = nil
        sink = nil
        source = nil
        pendingInputFormat = nil
        pendingOutputFormat = nil
        enginePrepared = false
    }

    /// Restarts the existing engine (voice processing often stops it once right after start).
    private func restartLocked(reason: String) {
        // Never start the microphone while the app is in the background.
        guard mayArm, let engine, !engine.isRunning, let sink, let source, let outputFormat else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        // Formats can change with the route; reconnect with what the hardware gives now.
        engine.disconnectNodeInput(sink)
        engine.connect(engine.inputNode, to: sink, format: micFormat)
        engine.disconnectNodeOutput(source)
        engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            trace("engine_restart_failed \(error.localizedDescription)")
            return
        }
        let rateChanged = micFormat.sampleRate != inputFormat?.sampleRate
        inputFormat = micFormat
        if rateChanged, let delegate {
            delegate.dispatchAsync { delegate.notifyAudioInputParametersChange() }
        }
        trace(String(format: "engine_restarted reason=%@ ms=%.0f inputRate=%.0f", reason,
                     Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, micFormat.sampleRate))
    }

    // MARK: - Real-time audio threads

    private func deliverMicrophone(timestamp: UnsafePointer<AudioTimeStamp>, frames: AVAudioFrameCount,
                                   buffers: UnsafePointer<AudioBufferList>) -> OSStatus {
        guard frames <= 4096 else { return noErr }
        if backlogResetRequested {
            backlogResetRequested = false
            backlogCount = 0
            backlogRead = 0
            capturedOnce = false
        }
        let sending = recording && released
        guard sending || buffering else { return noErr }
        // Channel 0 of the voice-processed microphone, Float32 → Int16.
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        guard let first = list.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let stride = Int(first.mNumberChannels)
        let count = Int(frames)
        for index in 0..<count {
            let sample = max(-1, min(1, data[index * stride]))
            scratch[index] = Int16(sample * 32767)
        }
        if !capturedOnce {
            capturedOnce = true
            onFirstCapture?()
        }
        if !sending {
            // Not connected yet: keep what the user says (up to 10 s) to send once it is.
            let room = min(count, backlogCapacity - backlogCount)
            if room > 0 {
                (backlog + backlogCount).update(from: scratch, count: room)
                backlogCount += room
            }
            return noErr
        }
        guard let deliver else { return noErr }
        var source = scratch
        var sendCount = count
        if backlogRead < backlogCount {
            // Catching up: live audio queues behind the backlog, which drains faster than real time.
            let room = min(count, backlogCapacity - backlogCount)
            (backlog + backlogCount).update(from: scratch, count: room)
            backlogCount += room
            sendCount = min(backlogCount - backlogRead, count * catchUpSpeed)
            source = backlog + backlogRead
            backlogRead += sendCount
            if backlogRead >= backlogCount {
                let total = backlogCount
                backlogCount = 0
                backlogRead = 0
                #if DEBUG
                // Copy the backlog for inspection before anything can overwrite it.
                if let dump = onBacklogDump { dump(Data(bytes: backlog, count: total * 2)) }
                #endif
                onBacklogDrained?(total)
            }
        }
        var status: OSStatus = noErr
        var offset = 0
        while offset < sendCount {
            let chunk = min(sendCount - offset, 1920)
            var converted = AudioBufferList(mNumberBuffers: 1,
                                            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(chunk * 2),
                                                                  mData: UnsafeMutableRawPointer(source + offset)))
            var flags = AudioUnitRenderActionFlags()
            status = deliver(&flags, timestamp, 1, UInt32(chunk), &converted, nil, nil)
            offset += chunk
        }
        if !deliveredOnce {
            deliveredOnce = true
            onFirstDelivery?()
            trace("first_deliver frames=\(sendCount) status=\(status)")
        }
        return status
    }

    private func renderPlayout(isSilence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                               frames: AVAudioFrameCount, output: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard playing, let playout else {
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
            return noErr
        }
        var flags = AudioUnitRenderActionFlags()
        let status = playout(&flags, timestamp, 0, frames, output)
        if !playedOnce {
            playedOnce = true
            trace("first_playout frames=\(frames) status=\(status)")
        }
        isSilence.pointee = ObjCBool(flags.contains(.unitRenderAction_OutputIsSilence))
        return status
    }
}

// MARK: - RTCAudioDevice

// WebRTC reads these on its own thread while applying the answer. They never touch
// AVAudioSession, whose getters block while the session is being activated elsewhere.
// Values are cached at arm time; until then, the iPhone's usual values are reported and
// WebRTC is told if the real ones differ.
extension HotAudioDevice: RTCAudioDevice {
    var deviceInputSampleRate: Double { inputFormat?.sampleRate ?? 48_000 }
    var deviceOutputSampleRate: Double { outputFormat?.sampleRate ?? 48_000 }
    var inputIOBufferDuration: TimeInterval { cachedIOBuffer }
    var outputIOBufferDuration: TimeInterval { cachedIOBuffer }
    var inputNumberOfChannels: Int { 1 }
    var outputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { cachedInputLatency }
    var outputLatency: TimeInterval { cachedOutputLatency }

    var isInitialized: Bool { delegate != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        trace("initialize preferredIn=\(delegate.preferredInputSampleRate) preferredOut=\(delegate.preferredOutputSampleRate)")
        deliver = delegate.deliverRecordedData
        playout = delegate.getPlayoutData
        self.delegate = delegate
        return true
    }

    func terminateDevice() -> Bool {
        trace("terminate")
        recording = false
        playing = false
        delegate = nil
        return true
    }

    var isPlayoutInitialized: Bool { delegate != nil }
    func initializePlayout() -> Bool { trace("initializePlayout"); return delegate != nil }
    var isPlaying: Bool { playing }
    func startPlayout() -> Bool {
        trace("startPlayout")
        ensureRunning()
        playedOnce = false
        playing = true
        return true
    }
    func stopPlayout() -> Bool { trace("stopPlayout"); playing = false; return true }

    /// Never builds a second engine on WebRTC's thread: arms if nothing exists yet,
    /// otherwise restarts the existing one in the background.
    private func ensureRunning() {
        queue.async {
            if self.engine == nil {
                // iOS refuses to start the microphone from the background; the controller arms
                // as soon as the app is active.
                guard self.mayArm else { self.trace("arm_deferred_background"); return }
                _ = try? self.armLocked()
            } else {
                self.restartLocked(reason: "start_request")
            }
        }
    }


    var isRecordingInitialized: Bool { delegate != nil }
    func initializeRecording() -> Bool { trace("initializeRecording"); return delegate != nil }
    var isRecording: Bool { recording }
    func startRecording() -> Bool {
        trace("startRecording")
        ensureRunning()
        deliveredOnce = false
        recording = true
        return true
    }
    // Buffering belongs to the call (the controller begins and ends it). WebRTC also calls
    // stop when unrelated peer connections close, such as the launch warm-up.
    func stopRecording() -> Bool { trace("stopRecording"); recording = false; return true }
}
