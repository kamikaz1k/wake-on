import AVFoundation
import Combine
import UIKit
import UserNotifications

struct AudioInputRoute: Equatable {
    let inputIDs: [String]
    let sampleRate: Double
    let channelCount: Int

    static func current() -> AudioInputRoute {
        let session = AVAudioSession.sharedInstance()
        return AudioInputRoute(inputIDs: session.currentRoute.inputs.map(\.uid),
                               sampleRate: session.sampleRate,
                               channelCount: session.inputNumberOfChannels)
    }

    func requiresRestart(current: AudioInputRoute, engineRunning: Bool,
                         reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .noSuitableRouteForCategory || !engineRunning || self != current
    }
}

/// UI is main-thread confined; all detector and buffer state is worker-queue confined.
final class WakeController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = WakeController()
    @Published var latencySummary = ""
    private var trace: LatencyTrace?
    private var workerTrace: LatencyTrace?
    private var direct = false // worker-queue confined
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var firstAudio = false // worker-queue confined
    private var callbackCount = 0
    private var maxQueueDelayMs = 0.0
    private var maxConvertMs = 0.0
    private var maxCopyMs = 0.0
    private var totalQueueDelayMs = 0.0
    private var totalConvertMs = 0.0
    private var lastAudioSampleEnd: Int64?
    private var missingInputFrames: Int64 = 0
    private var readyTimeout: DispatchWorkItem?
    @Published var status = "Listening is off"
    @Published var enabled = false
    @Published var busy = false
    @Published var handoff: AudioHandoff?
    @Published var wakeLocation = ""
    @Published var error: String?
    @Published var notificationNote = ""
    @Published var isPlaying = false
    private let queue = DispatchQueue(label: "wake.audio", qos: .userInitiated)
    private var engine = AVAudioEngine()
    private var captureRoute: AudioInputRoute?
    private var detector: WakeDetector?
    private var buffer = HandoffBuffer()
    private var running = false
    private var tapInstalled = false
    private var replayTrace: LatencyTrace?
    private var replay: AVAudioPlayer?
    private var replayTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var fixtureTimer: DispatchSourceTimer?
    private var fixtureSamples: [Float]?
    private var fixtureMode = false
    private var wakeWasBackground = false
    private var didComplete = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.trace?.mark("lifecycle", fields: ["notification": name.rawValue])
            })
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let self, self.enabled else { return }
                let message: String
                if name == AVAudioSession.routeChangeNotification {
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
                    let current = AudioInputRoute.current()
                    let mustStop = self.captureRoute?.requiresRestart(
                        current: current, engineRunning: self.engine.isRunning, reason: reason) ?? true
                    print("WAKE_AUDIO route reason=\(raw) inputChanged=\(self.captureRoute != current) engineRunning=\(self.engine.isRunning) stopping=\(mustStop)")
                    // setCategory/setActive can post this after startMicrophone returns.
                    // Output-only changes also leave our input converter valid.
                    guard mustStop else { return }
                    message = "The microphone connection or audio format changed. Tap Enable listening to resume."
                } else if name == AVAudioSession.interruptionNotification {
                    guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          type == AVAudioSession.InterruptionType.began.rawValue else { return }
                    print("WAKE_AUDIO interruption began")
                    message = "Another audio session interrupted listening. Tap Enable listening to resume."
                } else {
                    print("WAKE_AUDIO media services reset")
                    message = "The system audio service restarted. Tap Enable listening to resume."
                }
                self.stop()
                self.error = message
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    @MainActor
    func startDirect(source: String, entered: UInt64 = DispatchTime.now().uptimeNanoseconds) async throws {
        // Repeated presses join the same in-flight request; never discard speech.
        if busy || enabled, queue.sync(execute: { direct && !didComplete }) {
            trace?.mark("duplicate_request_joined")
            if queue.sync(execute: { firstAudio }) { return }
            try await withCheckedThrowingContinuation { readyWaiters.append($0) }
            return
        }
        let metric = LatencyTrace(source: source, origin: entered)
        metric.mark(source == "app_intent" ? "intent_entered" : "in_app_entered", at: entered)
        metric.mark("trace_initialized")
        trace?.finish("superseded")
        trace = metric
        if enabled && engine.isRunning {
            metric.mark("reuse_microphone")
            queue.sync { configureDirect(metric) }
            handoff = queue.sync { buffer.handoff }
            wakeLocation = "Started directly"
            status = "Waiting for first audio…"
        } else {
            trace = nil
            if busy || enabled || isPlaying { stop() }
            trace = metric
            busy = true
            status = "Preparing microphone…"
            error = nil
            handoff = nil
            generation += 1
            let token = generation
            queue.sync { configureDirect(metric) }
            metric.mark("permission_begin")
            if AVAudioApplication.shared.recordPermission == .granted {
                metric.mark("permission_end", fields: ["alreadyGranted": true])
                do { try startMicrophone(token: token) } catch { fail(error) }
            } else {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard token == generation else { throw WakeError.message("Recording was stopped.") }
                metric.mark("permission_end", fields: ["granted": granted])
                if granted {
                    do { try startMicrophone(token: token) } catch { fail(error) }
                } else { fail(WakeError.message("Enable microphone access in Settings.")) }
            }
        }
        if let error { throw WakeError.message(error) }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            if enabled { armReadyTimeout() }
        }
    }

    private func armReadyTimeout() {
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail(WakeError.message("Microphone produced no audio within five seconds."))
        }
        readyTimeout?.cancel()
        readyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func configureDirect(_ metric: LatencyTrace) {
        direct = true
        workerTrace = metric
        firstAudio = false
        callbackCount = 0
        maxQueueDelayMs = 0
        maxConvertMs = 0
        maxCopyMs = 0
        totalQueueDelayMs = 0
        totalConvertMs = 0
        lastAudioSampleEnd = nil
        missingInputFrames = 0
        detector = nil
        buffer = HandoffBuffer(tailFrames: 80_000)
        _ = buffer.trigger("DIRECT_RECORDING")
        didComplete = false
    }

    private func microphoneReady(_ metric: LatencyTrace) {
        guard trace === metric, enabled else { return }
        metric.mark("ready_ui")
        readyTimeout?.cancel()
        readyTimeout = nil
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
        status = queue.sync { direct } ? "Recording · speak now" : "Listening for Hey Lobby"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        metric.mark("ready_haptic_requested")
    }

    func start() {
        guard !enabled && !busy else { return }
        trace?.finish("superseded")
        trace = LatencyTrace(source: "wake_listener")
        trace?.mark("permission_begin")
        stopReplay()
        error = nil
        handoff = nil
        busy = true
        status = "Preparing microphone…"
        generation += 1
        let token = generation
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard granted else {
                    self.trace?.finish("permission_denied")
                    self.busy = false
                    self.status = "Microphone access needed"
                    self.error = "Enable microphone access in Settings to listen for Hey Lobby."
                    return
                }
                self.trace?.mark("permission_end", fields: ["granted": true])
                self.prepare(token: token)
            }
        }
    }

    private func prepare(token: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
            DispatchQueue.main.async {
                self?.notificationNote = allowed ? "Tap the wake notification to open the app." :
                    "Notifications are off. Open the app yourself after a background wake."
            }
        }
        let metric = trace
        queue.async {
            do {
                self.workerTrace = metric
                self.direct = false
                self.firstAudio = false
                self.callbackCount = 0
                self.maxQueueDelayMs = 0
                self.maxConvertMs = 0
                self.maxCopyMs = 0
                self.totalQueueDelayMs = 0
                self.totalConvertMs = 0
                self.lastAudioSampleEnd = nil
                self.missingInputFrames = 0
                self.workerTrace?.mark("model_begin")
                self.detector = try WakeDetector()
                self.workerTrace?.mark("model_end")
                self.buffer = HandoffBuffer()
                self.didComplete = false
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    do { try self.startMicrophone(token: token) }
                    catch { self.fail(error) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func startMicrophone(token: Int) throws {
        trace?.mark("session_configuration_begin")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        trace?.mark("session_activation_begin")
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        trace?.mark("session_activation_end", fields: ["actualIOBufferMs": session.ioBufferDuration * 1000,
                                                      "inputLatencyMs": session.inputLatency * 1000])
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WakeError.message("No microphone input is available.")
        }
        let converter = try MonoConverter(input: format)
        #if DEBUG
        fixtureMode = ProcessInfo.processInfo.arguments.contains("--fixture") ||
            ProcessInfo.processInfo.arguments.contains("--silence")
        #endif
        let usesFixture = fixtureMode
        queue.sync { running = true }
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] pcm, audioTime in
            let arrived = DispatchTime.now().uptimeNanoseconds
            guard let self, !usesFixture else { return }
            // AVAudioEngine owns pcm; copy it before returning from the callback.
            guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else { return }
            copy.frameLength = pcm.frameLength
            let src = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<src.count {
                if let to = dst[i].mData, let from = src[i].mData {
                    memcpy(to, from, Int(src[i].mDataByteSize))
                }
            }
            let copiedAt = DispatchTime.now().uptimeNanoseconds
            self.queue.async {
                guard self.running else { return }
                let workerStarted = DispatchTime.now().uptimeNanoseconds
                self.workerTrace?.mark("first_callback", at: arrived, fields: ["frames": Int(copy.frameLength),
                    "inputRate": copy.format.sampleRate,
                    "inputHostTimeValid": audioTime.isHostTimeValid,
                    "inputTimestampToCallbackMs": audioTime.isHostTimeValid ?
                        (Double(arrived) / 1e9 - AVAudioTime.seconds(forHostTime: audioTime.hostTime)) * 1000 : NSNull()], once: true)
                self.callbackCount += 1
                let queueDelay = Double(workerStarted - copiedAt) / 1e6
                self.maxQueueDelayMs = max(self.maxQueueDelayMs, queueDelay)
                self.totalQueueDelayMs += queueDelay
                self.maxCopyMs = max(self.maxCopyMs, Double(copiedAt - arrived) / 1e6)
                if audioTime.isSampleTimeValid {
                    if let end = self.lastAudioSampleEnd { self.missingInputFrames += max(0, audioTime.sampleTime - end) }
                    self.lastAudioSampleEnd = audioTime.sampleTime + Int64(copy.frameLength)
                }
                do {
                    let convertBegin = DispatchTime.now().uptimeNanoseconds
                    let converted = try converter.convert(copy)
                    let convertMs = Double(DispatchTime.now().uptimeNanoseconds - convertBegin) / 1e6
                    self.maxConvertMs = max(self.maxConvertMs, convertMs)
                    self.totalConvertMs += convertMs
                    self.ingest(converted)
                }
                catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
        tapInstalled = true
        trace?.mark("engine_prepare_begin")
        engine.prepare()
        trace?.mark("engine_start_begin")
        try engine.start()
        trace?.mark("engine_start_returned", fields: ["inputRate": format.sampleRate, "inputChannels": format.channelCount])
        captureRoute = AudioInputRoute.current()
        print("WAKE_AUDIO started inputRate=\(format.sampleRate) inputChannels=\(format.channelCount)")
        enabled = true
        busy = false
        status = "Waiting for first audio…"
        if !readyWaiters.isEmpty { armReadyTimeout() }
        if queue.sync(execute: { direct }) { handoff = queue.sync { buffer.handoff }; wakeLocation = "Started directly" }
        #if DEBUG
        if fixtureMode {
            let args = ProcessInfo.processInfo.arguments
            let delay = args.firstIndex(of: "--delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 2
            status = "Fixture test starts in \(Int(delay)) seconds"
            queue.asyncAfter(deadline: .now() + delay) {
                guard self.running else { return }
                do { try self.startFixture(silence: args.contains("--silence")) }
                catch { DispatchQueue.main.async { self.fail(error) } }
            }
        }
        #endif
    }

    private func ingest(_ samples: [Float]) {
        guard running else { return }
        if !samples.isEmpty && !firstAudio {
            firstAudio = true
            if let metric = workerTrace {
                metric.mark("first_samples", fields: ["sampleCount": samples.count])
                DispatchQueue.main.async { self.microphoneReady(metric) }
            }
        }
        // Blocks of at most 20 ms bound trigger granularity in fixture and live paths.
        for offset in stride(from: 0, to: samples.count, by: 320) {
            let block = Array(samples[offset..<min(offset + 320, samples.count)])
            buffer.append(block)
            if buffer.handoff == nil, let phrase = detector?.accept(block) {
                workerTrace?.mark("wake_detected")
                let capture = buffer.trigger(phrase)
                print("WAKE_AUDIO detected phrase=\(phrase) prerollFrames=\(capture.samples.count)")
                DispatchQueue.main.async {
                    guard self.enabled else { return }
                    self.wakeWasBackground = UIApplication.shared.applicationState == .background
                    self.wakeLocation = self.wakeWasBackground ? "Detected in background" : "Detected in foreground"
                    self.handoff = capture
                    self.status = "Wake detected · capturing handoff"
                    if self.wakeWasBackground { self.notifyWake() }
                }
            }
            if let capture = buffer.handoff, capture.complete, !didComplete {
                didComplete = true
                print("WAKE_AUDIO handoff complete frames=\(capture.samples.count)")
                workerTrace?.mark("handoff_worker_ready")
                let metric = workerTrace
                let isDirect = direct
                let summary: [String: Any] = ["frames": capture.samples.count, "audioDurationMs": capture.duration * 1000,
                    "callbackCount": callbackCount, "maxQueueDelayMs": maxQueueDelayMs,
                    "maxConvertMs": maxConvertMs, "maxCopyMs": maxCopyMs,
                    "meanQueueDelayMs": callbackCount > 0 ? totalQueueDelayMs / Double(callbackCount) : 0,
                    "meanConvertMs": callbackCount > 0 ? totalConvertMs / Double(callbackCount) : 0,
                    "missingInputFrames": missingInputFrames]
                let fixture = fixtureSamples
                DispatchQueue.main.async {
                    guard self.enabled, self.trace === metric else { return }
                    self.handoff = capture
                    self.status = "Audio handoff ready"
                    metric?.mark("handoff_ui_ready")
                    self.latencySummary = "Trace saved · \(capture.samples.count) frames · \(Int(summary["maxQueueDelayMs"] as? Double ?? 0)) ms max audio queue delay"
                    #if DEBUG
                    self.writeReport(capture, fixture: fixture)
                    #endif
                    if isDirect { self.stop(finalizeTrace: false); self.status = "Audio handoff ready" }
                    metric?.finish("completed", fields: summary)
                }
            }
        }
    }

    func stop(finalizeTrace: Bool = true) {
        trace?.mark("stop_requested")
        readyTimeout?.cancel()
        readyTimeout = nil
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: WakeError.message("Recording was stopped.")) }
        generation += 1
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        captureRoute = nil
        queue.sync {
            running = false
            fixtureTimer?.cancel()
            fixtureTimer = nil
            detector = nil
            fixtureSamples = nil
        }
        // Recreate after interruptions/media resets; do not retain an invalid audio graph.
        engine = AVAudioEngine()
        stopReplay()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        enabled = false
        busy = false
        status = "Listening is off"
        trace?.mark("microphone_stopped")
        if finalizeTrace { trace?.finish("stopped") }
    }

    func rearm() {
        guard enabled else { start(); return }
        stopReplay()
        handoff = nil
        wakeLocation = ""
        status = "Listening for Hey Lobby"
        let metric = LatencyTrace(source: "wake_rearm")
        trace?.finish("superseded")
        trace = metric
        queue.sync {
            workerTrace = metric
            direct = false
            firstAudio = false
            callbackCount = 0
            maxQueueDelayMs = 0
            maxConvertMs = 0
            maxCopyMs = 0
            totalQueueDelayMs = 0
            totalConvertMs = 0
            lastAudioSampleEnd = nil
            missingInputFrames = 0
            detector?.reset()
            buffer = HandoffBuffer()
            didComplete = false
        }
    }

    private func fail(_ failure: Error) {
        print("WAKE_AUDIO failure \(failure.localizedDescription)")
        trace?.mark("failure", fields: ["error": failure.localizedDescription])
        stop(finalizeTrace: false)
        trace?.finish("failed")
        error = failure.localizedDescription
        status = "Listening stopped"
    }

    private func notifyWake() {
        let content = UNMutableNotificationContent()
        content.title = "Hey Lobby heard you"
        content.body = "Your audio handoff is being captured. Tap to open Wake On."
        // Silent: do not inject a notification sound into the post-wake recording.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wake-handoff", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler() // The OS foregrounds the app after the user's tap; state already holds the handoff.
    }

    func playHandoff() {
        guard let capture = handoff, capture.complete else { return }
        if isPlaying { stopReplay(); return }
        do {
            // Detection is already paused after handoff. End measurement-mode capture
            // before playback: measurement intentionally reduces output dynamics/level.
            stop()
            replayTrace = LatencyTrace(source: "playback")
            status = "Audio handoff ready"
            replayTrace?.mark("playback_session_begin")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            replayTrace?.mark("playback_session_active")
            replay = try AVAudioPlayer(data: Self.wav(capture.samples))
            replay?.volume = 1
            guard replay?.play() == true else { throw WakeError.message("Could not play captured audio.") }
            replayTrace?.mark("playback_started")
            let peak = capture.samples.reduce(Float(0)) { max($0, abs($1)) }
            print("WAKE_AUDIO playback mode=\(session.mode.rawValue) outputs=\(session.currentRoute.outputs.map { $0.portType.rawValue }) systemVolume=\(session.outputVolume) peak=\(peak)")
            isPlaying = true
            replayTimer = Timer.scheduledTimer(withTimeInterval: capture.duration + 0.1, repeats: false) { [weak self] _ in
                self?.stopReplay()
            }
        } catch {
            stopReplay()
            self.error = error.localizedDescription
        }
    }
    private func stopReplay() {
        replay?.stop()
        replayTrace?.mark("playback_stopped")
        replayTrace?.finish("stopped")
        replayTrace = nil
        replay = nil
        replayTimer?.invalidate()
        replayTimer = nil
        isPlaying = false
        if !enabled { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000))
        number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16)); text("data")
        number(UInt32(samples.count * 2))
        for sample in samples { number(Int16(max(-1, min(1, sample)) * 32767)) }
        return data
    }

    #if DEBUG
    private func startFixture(silence: Bool) throws {
        var samples = [Float](repeating: 0, count: 32_000)
        if !silence {
            guard let url = Bundle.main.url(forResource: "wake-fixture", withExtension: "wav") else {
                throw WakeError.message("No fixture bundled. Run scripts/setup.sh.")
            }
            let file = try AVAudioFile(forReading: url)
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: pcm)
            samples += try MonoConverter(input: pcm.format).convert(pcm)
        }
        samples += [Float](repeating: 0, count: 80_000)
        fixtureSamples = samples
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if offset == samples.count {
                self.fixtureTimer?.cancel()
                self.fixtureTimer = nil
                if !self.didComplete {
                    DispatchQueue.main.async {
                        self.status = silence ? "Silence test complete · no wake" : "Fixture finished without a wake"
                        self.writeReport(nil, fixture: samples)
                    }
                }
                return
            }
            let end = min(offset + 320, samples.count)
            self.ingest(Array(samples[offset..<end]))
            offset = end
        }
        fixtureTimer = timer
        timer.resume()
    }
    private func writeReport(_ capture: AudioHandoff?, fixture: [Float]?) {
        var report: [String: Any] = ["source": fixture == nil ? "microphone" : "fixture",
                                   "detected": capture != nil, "backgroundAtWake": wakeWasBackground,
                                   "sampleRate": 16_000, "engineRunning": engine.isRunning,
                                   "recordedAt": ISO8601DateFormatter().string(from: Date())]
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--test-id"), index + 1 < args.count {
            report["testID"] = args[index + 1]
        }
        if let capture {
            report["phrase"] = capture.phrase
            report["startFrame"] = capture.startFrame
            report["wakeFrame"] = capture.wakeFrame
            report["endFrame"] = capture.endFrame
            report["sampleCount"] = capture.samples.count
            report["complete"] = capture.complete
            if let fixture, capture.endFrame <= fixture.count {
                report["exactBufferMatch"] = capture.samples == Array(fixture[capture.startFrame..<capture.endFrame])
            }
        }
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wake-report.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            print("WAKE_REPORT \(report)")
        } catch { self.error = "Could not save test report: \(error.localizedDescription)" }
    }
    #endif
}
