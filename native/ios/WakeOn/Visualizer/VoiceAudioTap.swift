import Foundation

enum VoiceSpeaker { case user, assistant }

/// Anything that can hand the visualizer the most recent audio for each speaker.
protocol VoiceAudioSource: AnyObject {
    /// Copies the newest `count` samples (oldest first) into `buffer`.
    /// Returns their sample rate, or nil when that speaker is producing no audio right now.
    @MainActor func latestSamples(for speaker: VoiceSpeaker, into buffer: UnsafeMutablePointer<Float>,
                                  count: Int, now: Double) -> Double?
}

/// The most recent audio samples, written by a real-time audio thread and read by the UI.
///
/// No locks and no allocation on the write path. A reader racing a writer can see a few
/// half-updated samples, which only shows up as one slightly noisy visualizer frame.
final class AudioSampleRing: @unchecked Sendable {
    static let capacity = 8192 // power of two; > the 2048-sample analysis window
    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: AudioSampleRing.capacity)
    /// Total samples ever written. Only the audio thread stores it; aligned word stores are atomic on arm64.
    private(set) var written = 0
    var sampleRate: Double = 48_000

    init() { buffer.initialize(repeating: 0, count: Self.capacity) }
    deinit { buffer.deallocate() }

    func write(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        var index = written
        let mask = Self.capacity - 1
        for i in 0..<count {
            buffer[index & mask] = samples[i * stride]
            index &+= 1
        }
        written = index
    }

    func write(int16 samples: UnsafePointer<Int16>, count: Int) {
        var index = written
        let mask = Self.capacity - 1
        for i in 0..<count {
            buffer[index & mask] = Float(samples[i]) * (1 / 32768)
            index &+= 1
        }
        written = index
    }

    /// Copies the newest `count` samples (oldest first). Returns `written` as seen by the copy.
    @discardableResult
    func copyLatest(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let end = written
        let n = min(count, Self.capacity)
        let mask = Self.capacity - 1
        for i in 0..<n {
            let index = end - n + i
            out[i] = index >= 0 ? buffer[index & mask] : 0
        }
        return end
    }
}

/// Live call audio: `HotAudioDevice` writes the microphone and the assistant's playout here.
final class VoiceAudioTap: VoiceAudioSource, @unchecked Sendable {
    static let shared = VoiceAudioTap()

    let microphone = AudioSampleRing()
    let assistant = AudioSampleRing()
    /// While muted the microphone is not recorded, so the visualizer stays quiet.
    var microphoneMuted = false

    // Main-actor bookkeeping: a ring that stops advancing means that speaker went quiet.
    private var seen: [VoiceSpeaker: (written: Int, at: Double)] = [:]
    private static let staleAfter = 0.15

    @MainActor
    func latestSamples(for speaker: VoiceSpeaker, into buffer: UnsafeMutablePointer<Float>,
                       count: Int, now: Double) -> Double? {
        let ring = speaker == .user ? microphone : assistant
        if speaker == .user && microphoneMuted { return nil }
        let written = ring.copyLatest(into: buffer, count: count)
        let last = seen[speaker]
        if last?.written != written { seen[speaker] = (written, now) }
        guard written > 0, now - (seen[speaker]?.at ?? 0) < Self.staleAfter else { return nil }
        return ring.sampleRate
    }
}
