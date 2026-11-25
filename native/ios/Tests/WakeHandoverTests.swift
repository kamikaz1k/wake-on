import AVFoundation
import XCTest
@testable import WakeOn

/// Regression guard: words said straight after "Hey Lobby" must reach the call. This broke
/// several times (late bridge start, a session switch that recorded silence for ~1 s, echo
/// cancellation switching on mid-sentence, the call engine's start muting the mic ~0.5 s);
/// each test pins one cause. Also check a device log with scripts/check-wake-handover.py.
final class WakeHandoverTests: XCTestCase {
    /// wake-fixture.wav is a "Hey Lobby" recording (recordings/positive), made before the
    /// assistant became Pixie, so these tests listen for that phrase.
    static let fixturePhrase = "Hey Lobby"

    /// A wake-word call reuses the listener's session in the foreground too. Switching to
    /// voice-chat mode took ~1 s on an iPhone 17 Pro, and the listener recorded silence meanwhile.
    func testEveryWakeWordCallKeepsTheListenerSession() {
        XCTAssertTrue(VoiceSessionController.keepsListenerSession(trigger: "wake_word"))
        // Action Button and in-app calls have no listener audio to keep: voice-chat mode.
        for trigger in ["app_intent_fast", "app_intent", "in_app", "url", "launch_argument"] {
            XCTAssertFalse(VoiceSessionController.keepsListenerSession(trigger: trigger), trigger)
        }
    }

    /// Switching echo cancellation on silences the mic for ~0.3 s. In a wake call that happened
    /// ~0.7 s after "Hey Lobby", mid-sentence; it now waits for Lobby's first reply.
    func testWakeCallsTurnOnEchoCancellationOnlyWhenLobbyReplies() {
        XCTAssertTrue(VoiceSessionController.defersVoiceProcessing(trigger: "wake_word"))
        for trigger in ["app_intent_fast", "app_intent", "in_app", "url", "launch_argument"] {
            XCTAssertFalse(VoiceSessionController.defersVoiceProcessing(trigger: trigger), trigger)
        }
        XCTAssertGreaterThanOrEqual(VoiceSessionController.voiceProcessingDeferLimit, 5)
    }

    /// The real model on the recorded "Hey Lobby": the call's audio (detection point minus the
    /// lookback) must start before the phrase ends, so nothing said after it is lost.
    func testCallAudioStartsBeforeTheWakePhraseEnds() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wake-fixture", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let speech = try MonoConverter(input: pcm.format).convert(pcm)
        let lead = 16_000
        let source = [Float](repeating: 0, count: lead) + speech + [Float](repeating: 0, count: 16_000)

        let detector = try WakeDetector(phrase: Self.fixturePhrase)
        var detectedAt: Int?
        for offset in stride(from: 0, to: source.count, by: 320) where detectedAt == nil {
            let block = Array(source[offset..<min(offset + 320, source.count)])
            if detector.accept(block) != nil { detectedAt = offset + block.count }
        }
        let detection = try XCTUnwrap(detectedAt, "The real model must detect the fixture")

        // Phrase end: after the first loud 20 ms frame (over 10% of the peak), the start of the
        // first 200 ms of quiet. On this fixture that is ~0.96 s into the recording.
        let frames = stride(from: 0, to: source.count, by: 320).map { start -> Float in
            let slice = source[start..<min(start + 320, source.count)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        let threshold = max((frames.max() ?? 0) * 0.1, 0.003)
        let first = try XCTUnwrap(frames.firstIndex { $0 > threshold })
        var quietRun = 0, endFrame = frames.count
        for index in first..<frames.count {
            quietRun = frames[index] > threshold ? 0 : quietRun + 1
            if quietRun == 10 { endFrame = index - 9; break }
        }
        let phraseStart = first * 320, phraseEnd = endFrame * 320
        XCTAssertLessThan(Double(phraseEnd - phraseStart) / 16_000, 1.2, "phrase end not found")

        let callStart = detection - Int(WakeController.bridgeLookback * 16_000)
        XCTAssertLessThanOrEqual(callStart, phraseEnd,
            "Call audio starts \(Double(callStart - phraseEnd) / 16) ms after the phrase ends; raise bridgeLookback")
        // And not absurdly early: the call shouldn't replay the whole phrase.
        XCTAssertGreaterThan(callStart, phraseStart)
    }

    /// Starting the call's audio engine mutes the iPhone's mic ~0.5 s, so wake calls start it
    /// only at the user's first pause; the listener records for the call until then.
    func testWakeCallsStartTheirAudioAtThePause() {
        XCTAssertTrue(VoiceSessionController.startsAudioAtPause(trigger: "wake_word"))
        for trigger in ["app_intent_fast", "app_intent", "in_app", "url", "launch_argument"] {
            XCTAssertFalse(VoiceSessionController.startsAudioAtPause(trigger: trigger), trigger)
        }
    }

    private func run(_ detector: inout PauseDetector, _ chunks: [(db: Double, seconds: Double)]) -> (String, Double)? {
        for chunk in chunks {
            if let reason = detector.add(levelDb: chunk.db, seconds: chunk.seconds) { return (reason, detector.elapsed) }
        }
        return nil
    }

    func testPauseDetectorWaitsThroughShortGapsBetweenWords() {
        var detector = PauseDetector()
        // Speech at -22 dB with 0.3 s gaps at -40 dB (as measured on the phone): no pause.
        let speech = Array(repeating: (db: -22.0, seconds: 0.1), count: 5)
        let gap = Array(repeating: (db: -40.0, seconds: 0.1), count: 3)
        XCTAssertNil(run(&detector, speech + gap + speech + gap + speech))
    }

    func testPauseDetectorFiresAfterSixTenthsOfQuiet() throws {
        var detector = PauseDetector()
        let speech = Array(repeating: (db: -22.0, seconds: 0.1), count: 10)
        let quiet = Array(repeating: (db: -45.0, seconds: 0.1), count: 10)
        let (reason, at) = try XCTUnwrap(run(&detector, speech + quiet))
        XCTAssertEqual(reason, "pause")
        XCTAssertEqual(at, 1.6, accuracy: 0.05)
    }

    func testPauseDetectorGivesUpAtTheLimit() throws {
        var detector = PauseDetector()
        // Loud music under continuous speech never goes quiet.
        let loud = Array(repeating: (db: -25.0, seconds: 0.1), count: 200)
        let (reason, at) = try XCTUnwrap(run(&detector, loud))
        XCTAssertEqual(reason, "limit")
        XCTAssertEqual(at, PauseDetector.limitSeconds, accuracy: 0.05)
    }

    /// Real model and recording ("Hey Lobby", then silence): the call's audio starts in the
    /// silence after the phrase, never during it.
    func testPauseComesAfterTheRecordedWakePhrase() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wake-fixture", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let source = try MonoConverter(input: pcm.format).convert(pcm) + [Float](repeating: 0, count: 32_000)
        let detector = try WakeDetector(phrase: Self.fixturePhrase)
        var detectedAt: Int?
        for offset in stride(from: 0, to: source.count, by: 320) where detectedAt == nil {
            let block = Array(source[offset..<min(offset + 320, source.count)])
            if detector.accept(block) != nil { detectedAt = offset + block.count }
        }
        let detection = try XCTUnwrap(detectedAt)
        // Listener chunks of 100 ms from the bridge start (detection minus the lookback).
        // Seeded like the app: the loudest 100 ms chunk of the 0.8 s kept before detection.
        func level(_ chunk: ArraySlice<Float>) -> Double {
            10 * log10(max(Double(chunk.reduce(0) { $0 + $1 * $1 }) / Double(chunk.count), 1e-12))
        }
        let kept = stride(from: max(0, detection - 12_800), to: detection, by: 1_600).map {
            level(source[$0..<min($0 + 1_600, detection)])
        }
        var pause = PauseDetector(peakDb: kept.max() ?? -120)
        var firedAt: Int?
        let bridgeStart = detection - Int(WakeController.bridgeLookback * 16_000)
        for start in stride(from: bridgeStart, to: source.count, by: 1_600) where firedAt == nil {
            let chunk = source[start..<min(start + 1_600, source.count)]
            if pause.add(levelDb: level(chunk), seconds: Double(chunk.count) / 16_000) != nil { firedAt = start + chunk.count }
        }
        let fired = try XCTUnwrap(firedAt, "no pause found after the phrase")
        // The phrase ends ~0.96 s into the recording (see testCallAudioStartsBeforeTheWakePhraseEnds).
        XCTAssertGreaterThan(Double(fired) / 16_000, 0.96 + PauseDetector.pauseSeconds - 0.05)
        XCTAssertLessThan(Double(fired) / 16_000, 0.96 + PauseDetector.pauseSeconds + 0.6)
    }

    /// The detector fires up to 0.36 s late on recordings/positive.
    func testLookbackCoversMeasuredDetectorLag() {
        XCTAssertGreaterThanOrEqual(WakeController.bridgeLookback, 0.36)
        XCTAssertLessThanOrEqual(WakeController.bridgeLookback, 0.6)
    }

    func testLookbackSlicesTakeTheEndOfEarlierChunks() {
        let slices = WakeController.lookbackSlices(lengths: [480, 480, 480], needed: 700)
        XCTAssertEqual(slices.map(\.index), [1, 2])
        XCTAssertEqual(slices.map(\.from), [260, 0])
    }

    func testLookbackSlicesUseEverythingKeptWhenShort() {
        let slices = WakeController.lookbackSlices(lengths: [480, 480], needed: 5_000)
        XCTAssertEqual(slices.map(\.index), [0, 1])
        XCTAssertEqual(slices.map(\.from), [0, 0])
        XCTAssertTrue(WakeController.lookbackSlices(lengths: [], needed: 100).isEmpty)
        XCTAssertTrue(WakeController.lookbackSlices(lengths: [480], needed: 0).isEmpty)
    }
}
