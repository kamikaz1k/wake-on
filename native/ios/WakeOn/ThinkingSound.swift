import Foundation

/// The soft sound a call plays while Pixie is quiet and working on something (a lookup, a page,
/// the calendar): a warm, quiet swell that breathes in and out, so a pause doesn't sound like a
/// dropped call. Mixed into the call's output by `HotAudioDevice`, so echo cancellation knows it.
enum ThinkingSound {
    static let enabledKey = "thinkingSound.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Starts only once tools have been running this long: quick lookups stay silent.
    static let lookupBefore = 3.0
    /// ...and Pixie has been quiet this long (its "one moment" first).
    static let quietBefore = 1.2
    /// A lookup step older than this isn't waited on any more (as for the idle check).
    static let lookupLimit = 30.0
    /// Stopping fades out over this long rather than cutting off.
    static let fadeSeconds = 0.15
    /// After a lookup, the sound waits this long at most for Pixie to start answering.
    static let answerWait = 6.0

    enum Style: String, CaseIterable {
        /// Two soft, low bell notes rising a fourth, every 1.6 s, like a gentle "hmm-mm".
        case pulse
        /// Three rising bell notes, every 2.2 s.
        case shimmer
        /// A warm swell that breathes in and out, every 1.8 s.
        case breath
    }

    static let style = Style.breath

    /// Whether a call should be playing it now.
    /// `waitingFor`: since the tools started (nil when nothing is running or being answered);
    /// `sinceLastStep`: since the latest tool step started.
    static func shouldPlay(live: Bool, waitingFor: Double?, sinceLastStep: Double, pixieQuietFor: Double,
                           connectionLost: Bool, muted: Bool) -> Bool {
        guard live, !connectionLost, !muted, let waitingFor, waitingFor >= lookupBefore,
              sinceLastStep < lookupLimit else { return false }
        return pixieQuietFor >= quietBefore
    }

    /// Plays the loop into a buffer, fading in and out at the gain's ramp. Owned by the render
    /// thread; pure, so the fade can be tested.
    struct Mixer {
        /// -1 while silent.
        private(set) var position = -1
        private(set) var gain = 0.0
        /// Gain change per sample (a full fade takes `fadeSeconds`).
        var step = 1 / (fadeSeconds * 48_000)
        /// After Pixie's voice, stay faded this many samples, so the gaps between its words don't
        /// bring the sound back (0.5 s).
        var holdLength = 24_000
        private var hold = 0

        /// Adds the sound to `samples`. `thinking`: it should play; `pixieLoud`: Pixie's voice is
        /// in this buffer. Returns true while anything was added.
        mutating func mix(_ loop: UnsafePointer<Int16>, length: Int, into samples: UnsafeMutablePointer<Int16>,
                          count: Int, thinking: Bool, pixieLoud: Bool) -> Bool {
            if pixieLoud { hold = holdLength } else { hold = max(0, hold - count) }
            let playing = thinking && hold == 0
            if position < 0 {
                guard playing, length > 0 else { return false }
                // The loop starts silent, so it can start at full gain.
                position = 0
                gain = 1
            }
            let target = playing ? 1.0 : 0.0
            for index in 0..<count {
                if gain < target { gain = min(target, gain + step) } else if gain > target { gain = max(target, gain - step) }
                if gain <= 0, !playing { position = -1; return true }
                if position >= length { position = 0 }
                let mixed = Int32(samples[index]) + Int32((Double(loop[position]) * gain).rounded())
                samples[index] = Int16(max(-32768, min(32767, mixed)))
                position += 1
            }
            return true
        }
    }

    /// One loop of the sound, Int16 mono. The loop starts with its notes and ends with the rest,
    /// so stopping at the end of a loop never cuts a note.
    static func loop(_ style: Style = style, sampleRate: Double) -> [Int16] {
        switch style {
        case .pulse:
            return bells([(587.3, 0), (784, 0.22)], decay: 0.2, level: 0.06, seconds: 1.6, sampleRate: sampleRate)
        case .shimmer:
            return bells([(523.3, 0), (659.3, 0.16), (784, 0.32)], decay: 0.24, level: 0.045, seconds: 2.2,
                         sampleRate: sampleRate)
        case .breath:
            return swell(frequencies: [330, 495], seconds: 1.8, swell: 1.2, level: 0.05, sampleRate: sampleRate)
        }
    }

    /// Soft bell notes: a pure sine with a 30 ms curved attack and an exponential decay.
    private static let attack = 0.03

    private static func bells(_ notes: [(frequency: Double, at: Double)], decay: Double, level: Double,
                              seconds: Double, sampleRate: Double) -> [Int16] {
        var mix = [Double](repeating: 0, count: Int(seconds * sampleRate))
        for note in notes {
            let start = Int(note.at * sampleRate)
            let length = min(mix.count - start, Int(decay * 6 * sampleRate))
            for n in 0..<max(0, length) {
                let t = Double(n) / sampleRate
                // A slow, curved attack and a pure sine: rounded, like the hang-up chime.
                let rise = min(1, t / attack)
                let envelope = sin(rise * .pi / 2) * sin(rise * .pi / 2) * exp(-t / decay)
                mix[start + n] += level * envelope * sin(2 * .pi * note.frequency * t)
            }
        }
        return mix.map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    /// A raised-cosine swell of a few sines, then silence.
    private static func swell(frequencies: [Double], seconds: Double, swell: Double, level: Double,
                              sampleRate: Double) -> [Int16] {
        let count = Int(seconds * sampleRate)
        let active = Int(swell * sampleRate)
        return (0..<count).map { n in
            guard n < active else { return 0 }
            let t = Double(n) / sampleRate
            let envelope = 0.5 - 0.5 * cos(2 * .pi * Double(n) / Double(active))
            let wave = frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(frequencies.count)
            return Int16(level * envelope * wave * 32767)
        }
    }

    /// 16-bit mono WAV, for previews.
    static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
}
