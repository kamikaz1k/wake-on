import AVFoundation
import XCTest
@testable import WakeOn

/// Regression guard: words said straight after "Hey Lobby" must reach the call. This broke
/// several times (late bridge start, a session switch that recorded silence for ~1 s, echo
/// cancellation switching on mid-sentence); each test pins one cause. Also check a device log with scripts/check-wake-handover.py.
final class WakeHandoverTests: XCTestCase {
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

        let detector = try WakeDetector()
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
