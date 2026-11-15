import XCTest
@testable import WakeOn

/// Feeds cumulative energy the way WebRTC reports it: level² × seconds, summed.
private struct EnergyFeed {
    var energy = 0.0
    var duration = 0.0
    mutating func advance(level: Double, seconds: Double = 0.05) -> (Double, Double) {
        energy += level * level * seconds
        duration += seconds
        return (energy, duration)
    }
}

final class VoiceActivityTests: XCTestCase {
    func testSpeechStartIsBackdatedAndStopIsTheLastLoudWindow() {
        var detector = AudioActivityDetector(startLevel: 0.02, stopLevel: 0.012, minimumSpeech: 0.1, hangover: 0.5)
        var feed = EnergyFeed()
        var time = 0.0
        var transitions: [AudioActivityDetector.Transition] = []
        func step(_ level: Double) {
            time += 0.05
            let (energy, duration) = feed.advance(level: level)
            if let t = detector.ingest(time: time, totalEnergy: energy, totalDuration: duration) { transitions.append(t) }
        }
        step(0)                                  // baseline sample
        for _ in 0..<10 { step(0.001) }          // 0.05 … 0.55 s quiet
        for _ in 0..<20 { step(0.1) }            // 0.55 … 1.55 s speech
        for _ in 0..<15 { step(0.001) }          // quiet again
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions[0].kind, .started)
        XCTAssertEqual(transitions[0].time, 0.55, accuracy: 0.001)
        XCTAssertEqual(transitions[1].kind, .stopped)
        XCTAssertEqual(transitions[1].time, 1.55, accuracy: 0.001)
    }

    func testShortClickAndShortPauseAreIgnored() {
        var detector = AudioActivityDetector(startLevel: 0.02, stopLevel: 0.012, minimumSpeech: 0.1, hangover: 0.5)
        var feed = EnergyFeed()
        var time = 0.0
        var kinds: [AudioActivityDetector.Transition.Kind] = []
        func step(_ level: Double) {
            time += 0.05
            let (energy, duration) = feed.advance(level: level)
            if let t = detector.ingest(time: time, totalEnergy: energy, totalDuration: duration) { kinds.append(t.kind) }
        }
        step(0)
        step(0.2)                                // 50 ms click: too short
        step(0.001); step(0.001)
        XCTAssertEqual(kinds, [])
        for _ in 0..<6 { step(0.1) }             // real speech
        for _ in 0..<4 { step(0.001) }           // 200 ms pause between words
        for _ in 0..<6 { step(0.1) }
        XCTAssertEqual(kinds, [.started])
    }

    func testTurnLatencyIsUserStopToReplyAudio() {
        var tracker = TurnTracker()
        var microphone = EnergyFeed()
        var remote = EnergyFeed()
        var time = 0.0
        var latencies: [Double] = []
        func step(user: Double, assistant: Double) {
            time += 0.05
            let (me, md) = microphone.advance(level: user)
            let (re, rd) = remote.advance(level: assistant)
            for event in tracker.ingest(time: time, microphoneEnergy: me, microphoneDuration: md,
                                        remoteEnergy: re, remoteDuration: rd) {
                if case .assistantStarted(let turn?) = event, let latency = turn.responseLatency { latencies.append(latency) }
            }
        }
        step(user: 0, assistant: 0)
        for _ in 0..<20 { step(user: 0.1, assistant: 0) }      // user talks until 1.05 s
        for _ in 0..<16 { step(user: 0.001, assistant: 0) }    // 800 ms of silence
        for _ in 0..<10 { step(user: 0.001, assistant: 0.2) }  // reply starts at 1.85 s
        XCTAssertEqual(latencies.count, 1)
        XCTAssertEqual(latencies[0], 0.8, accuracy: 0.001)
    }

    func testGoodbyeDetection() {
        for text in ["Okay, bye.", "Bye!", "Talk soon. Bye-bye.", "Goodbye.", "okay bye "] {
            XCTAssertTrue(VoiceSessionController.endsWithBye(text), text)
        }
        for text in ["Stand by.", "Anything else?", "Bye, and also", "Maybe", "abye"] {
            XCTAssertFalse(VoiceSessionController.endsWithBye(text), text)
        }
    }

    func testSessionRequestMatchesTheLiveAPI() throws {
        let body = LiveVoiceConfig().requestBody(sdp: "v=0")
        let session = try XCTUnwrap(body["session"] as? [String: Any])
        XCTAssertEqual(session["model"] as? String, "gpt-live-1")
        let delegation = try XCTUnwrap(session["delegation"] as? [String: Any])
        XCTAssertEqual(delegation["type"] as? String, "responses")
        let responses = try XCTUnwrap(delegation["responses"] as? [String: Any])
        let tools = try XCTUnwrap(responses["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "web_search")
        XCTAssertEqual(tools.map { $0["type"] as? String }, ["web_search", "function", "function", "function", "function", "function", "function"])
        let transport = try XCTUnwrap(body["transport"] as? [String: String])
        XCTAssertEqual(transport, ["type": "webrtc", "sdp": "v=0"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
}
