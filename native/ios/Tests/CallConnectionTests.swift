import XCTest
@testable import WakeOn

/// Patchy networks: a call rides out short drops (holding the user's audio) instead of hanging up.
final class CallConnectionTests: XCTestCase {
    func testDropIsLostUntilBothIceAndPathAreBack() {
        var link = CallConnection()
        XCTAssertEqual(link.state, .good)
        link.path(up: false, at: 10)
        XCTAssertEqual(link.state, .lost, "The phone losing its network shows at once, before ICE notices")
        link.ice(up: false, at: 13)
        link.path(up: true, at: 14)
        XCTAssertEqual(link.state, .lost, "Still lost until ICE reconnects")
        XCTAssertEqual(link.lostSince, 10)
        link.ice(up: true, at: 15)
        XCTAssertEqual(link.state, .good)
        XCTAssertNil(link.lostSince)
    }

    func testGivesUpAfterTheLimit() {
        var link = CallConnection()
        link.ice(up: false, at: 100)
        XCTAssertFalse(link.expired(at: 100 + CallConnection.lostLimit - 1))
        XCTAssertTrue(link.expired(at: 100 + CallConnection.lostLimit))
        link.ice(up: true, at: 110)
        XCTAssertFalse(link.expired(at: 1000))
    }

    func testPacketLossIsWeakThenSettles() {
        var link = CallConnection()
        // 50 packets a second, no loss.
        for step in 0...40 { link.stats(at: Double(step) * 0.1, received: step * 5, lost: 0, roundTripMs: 60) }
        XCTAssertEqual(link.state, .good)
        // 20% loss for two seconds.
        var received = 200, lost = 0
        for step in 41...60 {
            received += 4; lost += 1
            link.stats(at: Double(step) * 0.1, received: received, lost: lost, roundTripMs: 60)
        }
        XCTAssertEqual(link.state, .weak)
        // Clean again: weak until the window has no loss and it has settled.
        var time = 6.0
        while time < 6 + CallConnection.window + CallConnection.settle + 0.2 {
            time += 0.1; received += 5
            link.stats(at: time, received: received, lost: lost, roundTripMs: 60)
        }
        XCTAssertEqual(link.state, .good)
    }

    func testLongRoundTripIsWeak() {
        var link = CallConnection()
        link.stats(at: 1, received: 10, lost: 0, roundTripMs: 1200)
        XCTAssertEqual(link.state, .weak)
    }

    func testLostWinsOverWeakAndComesBackFresh() {
        var link = CallConnection()
        link.stats(at: 1, received: 10, lost: 0, roundTripMs: 1200)
        link.ice(up: false, at: 2)
        XCTAssertEqual(link.state, .lost)
        link.ice(up: true, at: 5)
        XCTAssertEqual(link.state, .good, "A reconnected link is judged afresh")
    }

    /// A blip must not end the call: only ICE failing (or the controller giving up) does.
    func testProviderKeepsTheCallOnDisconnect() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/CallConnectionTests.swift",
                                                                                 with: "WakeOn/OpenAILiveVoiceProvider.swift"), encoding: .utf8)
        let disconnected = try XCTUnwrap(source.range(of: "case .disconnected:"))
        let failed = try XCTUnwrap(source.range(of: "case .failed, .closed:"))
        XCTAssertFalse(source[disconnected.upperBound..<failed.lowerBound].contains("close("))
        XCTAssertTrue(source.contains("continualGatheringPolicy = .gatherContinually"))
    }
}

/// A voice note sends only its speech: silence sent at 4× had the model talk over nothing.
final class VoiceNoteCompactionTests: XCTestCase {
    func testKeepsSpeechWithPaddingAndDropsSilence() {
        // 10 s: silence, 1 s of tone at 4 s, silence.
        var audio = [Int16](repeating: 0, count: 480_000)
        for i in 192_000..<240_000 { audio[i] = Int16(8000 * sin(Double(i) * 0.05)) }
        let kept = audio.withUnsafeMutableBufferPointer { HotAudioDevice.compactSilence($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(Double(kept) / 48_000, 1.6, accuracy: 0.05, "1 s of speech plus 300 ms either side")
        XCTAssertNotEqual(audio[14_400 + 100], 0, "Speech starts 300 ms in")
        var silent = [Int16](repeating: 3, count: 96_000)
        XCTAssertEqual(silent.withUnsafeMutableBufferPointer { HotAudioDevice.compactSilence($0.baseAddress!, count: $0.count) }, 0)
    }
}
