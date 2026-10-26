import AVFoundation
import XCTest
@testable import WakeOn

/// The wake-word handover keeps listener audio exactly up to the call microphone's first frame.
final class WakeBridgeTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let base = AVAudioTime.hostTime(forSeconds: 1_000)

    private func chunk(_ frames: Int = 4_800) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { buffer.floatChannelData![0][index] = 0.25 }
        return buffer
    }
    private func at(_ ms: Double) -> UInt64 { base + AVAudioTime.hostTime(forSeconds: ms / 1000) }

    func testKeepsAudioUpToCallMicrophoneStart() {
        let device = HotAudioDevice()
        device.openBridge()
        XCTAssertEqual(device.feedBridge(chunk(), from: 0, hostTime: at(0)), .more)
        device.publishCallStartForTesting(at(150))
        XCTAssertEqual(device.feedBridge(chunk(), from: 0, hostTime: at(100)), .done)
        XCTAssertEqual(device.stagedFramesForTesting, 4_800 + 2_400, accuracy: 1)
        // Once done, later chunks are not staged.
        XCTAssertEqual(device.feedBridge(chunk(), from: 0, hostTime: at(200)), .done)
        XCTAssertEqual(device.stagedFramesForTesting, 7_200, accuracy: 1)
    }

    func testStartsAfterTheWakePhrase() {
        let device = HotAudioDevice()
        device.openBridge()
        XCTAssertEqual(device.feedBridge(chunk(), from: 960, hostTime: at(0)), .more)
        XCTAssertEqual(device.stagedFramesForTesting, 3_840)
    }

    func testCallStartBeforeChunkStagesNothingMore() {
        let device = HotAudioDevice()
        device.openBridge()
        device.publishCallStartForTesting(at(50))
        XCTAssertEqual(device.feedBridge(chunk(), from: 0, hostTime: at(100)), .done)
        XCTAssertEqual(device.stagedFramesForTesting, 0)
    }

    func testCancelledBridgeStopsFeeding() {
        let device = HotAudioDevice()
        device.openBridge()
        device.cancelBridge()
        XCTAssertEqual(device.feedBridge(chunk(), from: 0, hostTime: at(0)), .cancelled)
    }

    func testFullStagingEndsTheBridge() {
        let device = HotAudioDevice()
        device.openBridge()
        var result = HotAudioDevice.BridgeFeed.more
        for index in 0..<60 where result == .more {
            result = device.feedBridge(chunk(), from: 0, hostTime: at(Double(index) * 100))
        }
        XCTAssertEqual(result, .done)
        XCTAssertEqual(device.stagedFramesForTesting, 240_000)
    }
}
