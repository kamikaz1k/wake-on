import Accelerate
import Foundation

/// Everything a visualizer needs for one display frame.
struct VoiceFrame: Sendable {
    static let bandCount = 32
    static let historyCount = 120 // 25 ms apart: the last 3 seconds of loudness
    static let waveRows = 64      // 30 ms apart

    /// Seconds since the signal started.
    var time: Float = 0
    /// Smoothed loudness, 0…1.
    var userLevel: Float = 0
    var assistantLevel: Float = 0
    var level: Float = 0
    /// Who is talking: 0 = user, 1 = assistant (eased, so colors cross-fade).
    var mix: Float = 0
    /// 0…1 while the assistant is expected to answer.
    var thinking: Float = 0
    /// A spring that follows `level` with overshoot: the "bounce".
    var spring: Float = 0
    var springVelocity: Float = 0
    /// Spectrum, 80 Hz – 8 kHz on a log scale, 0…1, gated by who is talking.
    var bands = [Float](repeating: 0, count: VoiceFrame.bandCount)
    /// Loudness history, newest first.
    var history = [Float](repeating: 0, count: VoiceFrame.historyCount)
    /// Spectrum history for the wave orb: rows newest first, each row is (band, mix) × 32.
    var waveHistory = [Float](repeating: 0, count: VoiceFrame.bandCount * VoiceFrame.waveRows * 2)
    /// Accumulated cloud drift for the sky orb (moves faster when louder).
    var skyFlow: Float = 0
    /// Accumulated spin for the wave orb.
    var waveRotation: Float = 0

    var isUserSpeaking: Bool { userLevel > 0.25 }
    var isAssistantSpeaking: Bool { assistantLevel > 0.25 }
}

/// Turns raw samples into loudness and a 32-band spectrum, the same way Web Audio's
/// AnalyserNode does (Blackman window, 2048-point FFT, smoothing 0.55, −95…−25 dB).
/// Matching it keeps the native visualizers identical to the browser prototype.
final class SpectrumAnalyzer {
    static let size = 2048
    private static let minDecibels: Float = -95
    private static let maxDecibels: Float = -25
    private static let smoothing: Float = 0.55

    private let dft = vDSP.DFT(count: SpectrumAnalyzer.size, direction: .forward,
                               transformType: .complexComplex, ofType: Float.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .blackman,
                                     count: SpectrumAnalyzer.size, isHalfWindow: false)
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private let zeros = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var outReal = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var outImag = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)

    /// Returns the RMS level in dBFS and writes 32 band values (0…1) into `bands`.
    func analyse(_ samples: UnsafePointer<Float>, sampleRate: Double, bands: inout [Float]) -> Float {
        let n = Self.size
        let input = UnsafeBufferPointer(start: samples, count: n)
        let meanSquare = vDSP.meanSquare(input)
        vDSP.multiply(input, window, result: &windowed)
        dft.transform(inputReal: windowed, inputImaginary: zeros, outputReal: &outReal, outputImaginary: &outImag)
        let bins = n / 2
        let k = Self.smoothing
        for i in 0..<bins {
            let magnitude = (outReal[i] * outReal[i] + outImag[i] * outImag[i]).squareRoot() / Float(n)
            smoothed[i] = k * smoothed[i] + (1 - k) * magnitude
        }
        let nyquist = sampleRate / 2
        for band in 0..<VoiceFrame.bandCount {
            let f0 = 80 * pow(100, Double(band) / 32), f1 = 80 * pow(100, Double(band + 1) / 32)
            let a = Int(f0 / nyquist * Double(bins))
            let b = max(a + 1, Int((f1 / nyquist * Double(bins)).rounded(.up)))
            var peak: Float = 0
            var j = a
            while j < b && j < bins { peak = max(peak, smoothed[j]); j += 1 }
            let db = 20 * log10(max(peak, 1e-12))
            bands[band] = min(1, max(0, (db - Self.minDecibels) / (Self.maxDecibels - Self.minDecibels)))
        }
        return 10 * log10(meanSquare + 1e-12)
    }

    func reset() { for i in smoothed.indices { smoothed[i] = 0 } }
}

/// Reads a `VoiceAudioSource` once per display frame and produces a `VoiceFrame`.
/// Several visualizers can share one signal; each frame is computed once.
@MainActor
final class VoiceSignal {
    /// The live call: microphone and assistant audio from `HotAudioDevice`.
    static let live = VoiceSignal(source: VoiceAudioTap.shared)
    /// A synthetic conversation for SwiftUI previews.
    static func simulated() -> VoiceSignal { VoiceSignal(source: nil) }

    /// Set to force the thinking state; nil infers it from the audio (a pause after the user spoke).
    var thinkingOverride: Bool?

    private weak var source: VoiceAudioSource?
    private let simulated: Bool
    private let userAnalyzer = SpectrumAnalyzer()
    private let assistantAnalyzer = SpectrumAnalyzer()
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: SpectrumAnalyzer.size)
    private var userRaw = [Float](repeating: 0, count: VoiceFrame.bandCount)
    private var assistantRaw = [Float](repeating: 0, count: VoiceFrame.bandCount)
    private var userBands = [Float](repeating: 0, count: VoiceFrame.bandCount)
    private var assistantBands = [Float](repeating: 0, count: VoiceFrame.bandCount)
    private var frame = VoiceFrame()
    private var origin: Double?
    private var lastTime: Double = -1
    private var historyClock: Double = 0
    private var waveClock: Double = 0
    // Thinking inference.
    private var speechStart: Double?
    private var lastVoice: Double = 0
    private var awaitingReplySince: Double?

    init(source: VoiceAudioSource?) {
        self.source = source
        self.simulated = source == nil
    }

    deinit { scratch.deallocate() }

    func frame(at date: Date) -> VoiceFrame {
        let now = date.timeIntervalSinceReferenceDate
        if abs(now - lastTime) < 0.002 { return frame }
        let start = origin ?? now
        origin = start
        let dt = Float(min(0.05, max(0, lastTime < 0 ? 1.0 / 60 : now - lastTime)))
        lastTime = now
        step(now: now, t: Float(now - start), dt: dt)
        return frame
    }

    // MARK: - Per-frame update

    private static func ease(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }
    private static func normalize(_ db: Float) -> Float { min(1, max(0, (db + 52) / 38)) }

    private func step(now: Double, t: Float, dt: Float) {
        var userDb: Float = -120, assistantDb: Float = -120
        if simulated {
            simulate(t: t, userDb: &userDb, assistantDb: &assistantDb)
        } else if let source {
            userDb = analyse(source, .user, now: now, analyzer: userAnalyzer, into: &userRaw)
            assistantDb = analyse(source, .assistant, now: now, analyzer: assistantAnalyzer, into: &assistantRaw)
        } else {
            for i in 0..<VoiceFrame.bandCount { userRaw[i] = 0; assistantRaw[i] = 0 }
        }

        var f = frame
        f.time = t
        let follow: (Float, Float) -> Float = { cur, target in
            cur + (target - cur) * Self.ease(target > cur ? 48 : 9, dt)
        }
        f.userLevel = follow(f.userLevel, Self.normalize(userDb))
        f.assistantLevel = follow(f.assistantLevel, Self.normalize(assistantDb))
        let kb = Self.ease(30, dt)
        let userGate = min(1, f.userLevel * 1.6), assistantGate = min(1, f.assistantLevel * 1.6)
        for i in 0..<VoiceFrame.bandCount {
            userBands[i] += (userRaw[i] - userBands[i]) * kb
            assistantBands[i] += (assistantRaw[i] - assistantBands[i]) * kb
            f.bands[i] = max(userBands[i] * userGate, assistantBands[i] * assistantGate)
        }
        f.level = max(f.userLevel, f.assistantLevel)
        let total = f.userLevel + f.assistantLevel
        let targetMix = total > 0.05 ? f.assistantLevel / total : f.mix
        f.mix += (targetMix - f.mix) * Self.ease(7, dt)

        let thinking = thinkingOverride ?? inferThinking(now: now, user: f.userLevel, assistant: f.assistantLevel)
        f.thinking += ((thinking ? 1 : 0) - f.thinking) * Self.ease(5, dt)

        for _ in 0..<max(1, Int((dt * 60).rounded())) {
            f.springVelocity += (f.level - f.spring) * 0.2
            f.springVelocity *= 0.76
            f.spring += f.springVelocity
        }
        f.skyFlow += dt * (0.22 + f.level * 1.5 + f.thinking * 0.5)
        f.waveRotation += dt * (0.18 + f.level * 0.5)

        historyClock += Double(dt)
        while historyClock > 0.025 {
            historyClock -= 0.025
            f.history.removeLast()
            f.history.insert(f.level, at: 0)
        }
        waveClock += Double(dt)
        while waveClock > 0.03 {
            waveClock -= 0.03
            let row = VoiceFrame.bandCount * 2
            let count = f.waveHistory.count
            f.waveHistory.withUnsafeMutableBufferPointer { buffer in
                var i = count - 1
                while i >= row { buffer[i] = buffer[i - row]; i -= 1 }
                for band in 0..<VoiceFrame.bandCount {
                    buffer[band * 2] = min(1, f.bands[band] * 1.137)
                    buffer[band * 2 + 1] = f.mix
                }
            }
        }
        frame = f
    }

    private func analyse(_ source: VoiceAudioSource, _ speaker: VoiceSpeaker, now: Double,
                         analyzer: SpectrumAnalyzer, into bands: inout [Float]) -> Float {
        guard let rate = source.latestSamples(for: speaker, into: scratch, count: SpectrumAnalyzer.size, now: now) else {
            for i in 0..<bands.count { bands[i] = 0 }
            return -120
        }
        return analyzer.analyse(scratch, sampleRate: rate, bands: &bands)
    }

    /// The user spoke, then paused: expect the assistant to answer for a few seconds.
    private func inferThinking(now: Double, user: Float, assistant: Float) -> Bool {
        if user > 0.38 {
            if speechStart == nil { speechStart = now }
            lastVoice = now
            awaitingReplySince = nil
        } else if let start = speechStart, now - lastVoice > 0.8 {
            if lastVoice - start > 0.35 { awaitingReplySince = now }
            speechStart = nil
        }
        if assistant > 0.3 { awaitingReplySince = nil }
        guard let since = awaitingReplySince else { return false }
        if now - since > 6 { awaitingReplySince = nil; return false }
        return true
    }

    /// A looping fake conversation (idle → user → thinking → assistant) for previews.
    private func simulate(t: Float, userDb: inout Float, assistantDb: inout Float) {
        let phase = t.truncatingRemainder(dividingBy: 11.3)
        func speech(_ k: Float) -> Float {
            let syllable = pow(max(0, sin(t * k)), 2)
            return min(1, syllable * (0.55 + 0.45 * sin(t * 1.7)) + max(0, sin(t * k * 2.7)) * 0.2)
        }
        func fill(_ bands: inout [Float], _ level: Float) {
            for i in 0..<bands.count {
                bands[i] = level * (0.45 + 0.55 * abs(sin(t * (4 + Float(i) * 0.9) + Float(i) * 1.3))) * (1 - Float(i) / 40)
            }
        }
        let user: Float = phase > 1.5 && phase < 5 ? speech(11) : 0
        let assistant: Float = phase > 6.8 ? speech(13) : 0
        userDb = user > 0.01 ? -50 + user * 36 : -120
        assistantDb = assistant > 0.01 ? -50 + assistant * 36 : -120
        fill(&userRaw, user > 0.01 ? 0.7 + user * 0.3 : 0)
        fill(&assistantRaw, assistant > 0.01 ? 0.7 + assistant * 0.3 : 0)
        thinkingOverride = phase > 5 && phase < 6.8
    }
}
