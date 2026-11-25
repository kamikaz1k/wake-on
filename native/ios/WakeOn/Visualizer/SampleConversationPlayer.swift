import AVFoundation
import Foundation

/// Plays a short two-voice conversation (bundled `viz-*.wav`: OpenAI gpt-4o-mini-tts, Pixie in its
/// default call voice Marin, the user in Cedar, made with a casual-speech prompt) and serves
/// its audio to a `VoiceSignal`, so the visualizers can be judged on real speech
/// without starting a call. Includes one interruption.
@MainActor
final class SampleConversationPlayer: ObservableObject, VoiceAudioSource {
    @Published private(set) var isPlaying = false
    @Published private(set) var caption = ""
    @Published private(set) var captionIsUser = true
    @Published var error: String?

    private(set) lazy var signal = VoiceSignal(source: self)

    private let engine = AVAudioEngine()
    private let userNode = AVAudioPlayerNode()
    private let assistantNode = AVAudioPlayerNode()
    private var clips: [String: AVAudioPCMBuffer] = [:]
    private var current: [VoiceSpeaker: AVAudioPCMBuffer] = [:]
    private var runID = 0
    private var thinkingUntil: Double?

    private static let lines: [String: String] = [
        "u1": "Hey, can you check if my flight to Lisbon is still on time?",
        "a1": "Sure. Your flight TP 238 leaves at 6:40 this evening, and it's currently on time. Boarding starts at 6:05, from gate B12.",
        "u2": "Great. And what's the weather like when I land?",
        "a2": "Lisbon will be around 19 degrees and clear when you land, with a light breeze off the river. You probably won't need a jacket, but maybe bring something light for later in the evening, because it can get—",
        "u3": "Sorry, quick one, is that Celsius?",
        "a3": "Yes, 19 Celsius. That's about 66 Fahrenheit.",
    ]

    func play() {
        stop()
        do { try prepare() } catch {
            self.error = "Couldn't start sample audio: \(error.localizedDescription)"
            return
        }
        error = nil
        isPlaying = true
        runID += 1
        let id = runID
        Task { await run(id) }
    }

    func stop() {
        runID += 1
        userNode.stop()
        assistantNode.stop()
        current = [:]
        thinkingUntil = nil
        signal.thinkingOverride = nil
        isPlaying = false
    }

    // MARK: - Script

    private func run(_ id: Int) async {
        func live() -> Bool { id == runID }
        await sleep(0.4); guard live() else { return }
        await say("u1", .user); guard live() else { return }
        await think(0.9); guard live() else { return }
        await say("a1", .assistant); guard live() else { return }
        await sleep(0.5); guard live() else { return }
        await say("u2", .user); guard live() else { return }
        await think(1.0); guard live() else { return }
        // The user cuts in about 2.3 s before "it can get—" ends, and Pixie fades out under them.
        Task { await say("a2", .assistant) }
        await sleep(max(0, seconds("a2") - 2.3)); guard live() else { return }
        Task { await say("u3", .user) }
        await sleep(0.45); guard live() else { return }
        await fadeOut(assistantNode, seconds: 0.26); guard live() else { return }
        await sleep(max(0, seconds("u3") - 0.71)); guard live() else { return }
        await think(0.7); guard live() else { return }
        await say("a3", .assistant); guard live() else { return }
        caption = "End of sample."
        isPlaying = false
    }

    private func seconds(_ name: String) -> Double {
        guard let clip = clips[name] else { return 0 }
        return Double(clip.frameLength) / clip.format.sampleRate
    }

    private func say(_ name: String, _ speaker: VoiceSpeaker) async {
        guard let buffer = clips[name] else { return }
        let node = speaker == .user ? userNode : assistantNode
        caption = Self.lines[name] ?? ""
        captionIsUser = speaker == .user
        node.stop()
        node.volume = 1
        current[speaker] = buffer
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                done.resume()
            }
            node.play()
        }
    }

    private func think(_ seconds: Double) async {
        signal.thinkingOverride = true
        caption = "…"
        await sleep(seconds)
        signal.thinkingOverride = nil
    }

    private func fadeOut(_ node: AVAudioPlayerNode, seconds: Double) async {
        let steps = 10
        for i in 1...steps {
            node.volume = 1 - Float(i) / Float(steps)
            await sleep(seconds / Double(steps))
        }
        node.stop()
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    // MARK: - Audio

    private func prepare() throws {
        if clips.isEmpty {
            for name in Self.lines.keys {
                guard let url = Bundle.main.url(forResource: "viz-\(name)", withExtension: "wav") else {
                    throw VoiceError.message("Missing sample clip \(name).")
                }
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buffer)
                clips[name] = buffer
            }
        }
        let session = AVAudioSession.sharedInstance()
        // Leave a running wake listener's play-and-record session alone.
        if session.category != .playAndRecord {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try session.setActive(true)
        if engine.attachedNodes.contains(userNode) == false, let format = clips.values.first?.format {
            engine.attach(userNode)
            engine.attach(assistantNode)
            engine.connect(userNode, to: engine.mainMixerNode, format: format)
            engine.connect(assistantNode, to: engine.mainMixerNode, format: format)
        }
        if !engine.isRunning { try engine.start() }
    }

    /// Reads the samples each player is rendering right now, straight from the clip.
    func latestSamples(for speaker: VoiceSpeaker, into buffer: UnsafeMutablePointer<Float>,
                       count: Int, now: Double) -> Double? {
        let node = speaker == .user ? userNode : assistantNode
        guard node.isPlaying, let clip = current[speaker], let samples = clip.floatChannelData?[0],
              let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return nil }
        let position = Int(playerTime.sampleTime)
        let length = Int(clip.frameLength)
        guard position > 0, position < length + count else { return nil }
        let gain = node.volume
        for i in 0..<count {
            let index = position - count + i
            buffer[i] = index >= 0 && index < length ? samples[index] * gain : 0
        }
        return clip.format.sampleRate
    }
}
