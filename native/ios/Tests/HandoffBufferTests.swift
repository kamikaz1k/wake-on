import XCTest
import AVFoundation
@testable import WakeOn

final class HandoffBufferTests: XCTestCase {
    func testDirectCapturePreservesFirstSampleAndStopsExactlyAtFiveSeconds() {
        var buffer = HandoffBuffer(tailFrames: 80_000)
        let initial = buffer.trigger("DIRECT_RECORDING")
        XCTAssertTrue(initial.samples.isEmpty)
        let input = (0..<81_123).map { Float($0) / 100_000 }
        for offset in stride(from: 0, to: input.count, by: 1024) {
            buffer.append(Array(input[offset..<min(offset + 1024, input.count)]))
        }
        XCTAssertEqual(buffer.handoff?.samples, Array(input.prefix(80_000)))
        XCTAssertEqual(buffer.handoff?.startFrame, 0)
        XCTAssertEqual(buffer.handoff?.wakeFrame, 0)
        XCTAssertEqual(buffer.handoff?.duration, 5)
        XCTAssertEqual(buffer.handoff?.complete, true)
    }

    func testOwnStartupAndOutputRouteChangesDoNotStopCapture() {
        let microphone = AudioInputRoute(inputIDs: ["built-in"], sampleRate: 48_000, channelCount: 1)
        for reason in [AVAudioSession.RouteChangeReason.categoryChange, .override, .routeConfigurationChange] {
            XCTAssertFalse(microphone.requiresRestart(current: microphone, engineRunning: true, reason: reason))
        }
    }

    func testLostOrChangedInputAndStoppedEngineStillStopCapture() {
        let microphone = AudioInputRoute(inputIDs: ["built-in"], sampleRate: 48_000, channelCount: 1)
        let bluetooth = AudioInputRoute(inputIDs: ["bluetooth"], sampleRate: 16_000, channelCount: 1)
        let changedRate = AudioInputRoute(inputIDs: ["built-in"], sampleRate: 44_100, channelCount: 1)
        XCTAssertTrue(microphone.requiresRestart(current: bluetooth, engineRunning: true, reason: .newDeviceAvailable))
        XCTAssertTrue(microphone.requiresRestart(current: changedRate, engineRunning: true, reason: .routeConfigurationChange))
        XCTAssertTrue(microphone.requiresRestart(current: microphone, engineRunning: false, reason: .categoryChange))
        XCTAssertTrue(microphone.requiresRestart(current: microphone, engineRunning: true, reason: .noSuitableRouteForCategory))
    }

    func testWrappedPrerollAndTailHaveNoGapOrDuplicate() {
        var buffer = HandoffBuffer(prerollFrames: 5, tailFrames: 4)
        buffer.append([0, 1, 2])
        buffer.append([3, 4, 5, 6])
        let initial = buffer.trigger("HEY_LOBBY")
        XCTAssertEqual(initial.samples, [2, 3, 4, 5, 6])
        XCTAssertEqual(initial.startFrame, 2)
        XCTAssertEqual(initial.wakeFrame, 7)
        buffer.append([7, 8])
        XCTAssertFalse(buffer.handoff!.complete)
        buffer.append([9, 10, 11, 12])
        XCTAssertEqual(buffer.handoff!.samples, [2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(buffer.handoff!.endFrame, 11)
        XCTAssertTrue(buffer.handoff!.complete)
        buffer.append([13, 14])
        XCTAssertEqual(buffer.handoff!.samples.count, 9)
    }

    func testEarlyWakeHasOnlyActualPreroll() {
        var buffer = HandoffBuffer(prerollFrames: 10, tailFrames: 2)
        buffer.append([1, 2])
        let capture = buffer.trigger("wake")
        XCTAssertEqual(capture.startFrame, 0)
        XCTAssertEqual(capture.samples, [1, 2])
        buffer.append([3, 4])
        XCTAssertEqual(buffer.handoff!.samples, [1, 2, 3, 4])
        XCTAssertTrue(buffer.handoff!.complete)
    }

    func testRealModelDetectsFixtureAndPreservesExactHandoff() throws {
        let detector = try WakeDetector()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wake-fixture", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let speech = try MonoConverter(input: pcm.format).convert(pcm)
        let source = [Float](repeating: 0, count: 32_000) + speech +
            [Float](repeating: 0, count: 80_000)
        var buffer = HandoffBuffer()
        for offset in stride(from: 0, to: source.count, by: 320) {
            let block = Array(source[offset..<min(offset + 320, source.count)])
            buffer.append(block)
            if buffer.handoff == nil, let phrase = detector.accept(block) {
                _ = buffer.trigger(phrase)
            }
        }
        let capture = try XCTUnwrap(buffer.handoff, "The real Sherpa model must detect the positive recording")
        XCTAssertEqual(capture.phrase, "HEY_LOBBY")
        XCTAssertTrue(capture.complete)
        XCTAssertEqual(capture.samples.count, 80_000)
        XCTAssertEqual(capture.wakeFrame - capture.startFrame, 32_000)
        XCTAssertEqual(capture.endFrame - capture.wakeFrame, 48_000)
        XCTAssertEqual(capture.samples, Array(source[capture.startFrame..<capture.endFrame]))
    }

    func testRealModelDoesNotWakeOnSilence() throws {
        let detector = try WakeDetector()
        for _ in 0..<500 {
            XCTAssertNil(detector.accept([Float](repeating: 0, count: 320)))
        }
    }

    func testStreamingResamplingKeepsSpeechDetectable() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wake-fixture", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        XCTAssertEqual(pcm.format.sampleRate, 16_000)
        // Sample-and-hold upsamples the original speech to exercise the live 48→16 kHz converter.
        let original = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        let source = original.flatMap { [$0, $0, $0] } + [Float](repeating: 0, count: 48_000)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 1, interleaved: false))
        let converter = try MonoConverter(input: format)
        let detector = try WakeDetector()
        var phrases: [String] = []
        for offset in stride(from: 0, to: source.count, by: 960) {
            let chunk = Array(source[offset..<min(offset + 960, source.count)])
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(chunk.count)))
            input.frameLength = UInt32(chunk.count)
            chunk.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            if let phrase = detector.accept(try converter.convert(input)) { phrases.append(phrase) }
        }
        XCTAssertTrue(phrases.contains("HEY_LOBBY"))
    }
}
