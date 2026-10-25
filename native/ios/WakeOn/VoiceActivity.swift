import Foundation

/// Finds where speech starts and stops from WebRTC's cumulative audio statistics.
///
/// WebRTC reports `totalAudioEnergy` (sum of level² × seconds) and
/// `totalSamplesDuration` for both the microphone and the incoming audio. The
/// difference between two samples gives the mean level for that window, so a
/// 50 ms polling interval sees every bit of audio, not just the instant of the poll.
struct AudioActivityDetector {
    struct Transition: Equatable {
        enum Kind: Equatable { case started, stopped }
        let kind: Kind
        /// Uptime in seconds. `stopped` is back-dated to the end of the last loud window.
        let time: Double
    }

    var startLevel: Double
    var stopLevel: Double
    /// Speech must stay loud this long before it counts (filters clicks).
    var minimumSpeech: Double
    /// Quiet this long ends speech (spans pauses between words).
    var hangover: Double

    private(set) var active = false
    private var lastEnergy: Double?
    private var lastDuration: Double?
    private var candidateStart: Double?
    private var lastLoudEnd: Double?
    private(set) var lastLevel: Double = 0

    init(startLevel: Double = 0.02, stopLevel: Double = 0.012, minimumSpeech: Double = 0.1, hangover: Double = 0.5) {
        self.startLevel = startLevel
        self.stopLevel = stopLevel
        self.minimumSpeech = minimumSpeech
        self.hangover = hangover
    }

    /// Feeds one statistics sample taken at `time`. Returns at most one transition.
    mutating func ingest(time: Double, totalEnergy: Double, totalDuration: Double) -> Transition? {
        defer { lastEnergy = totalEnergy; lastDuration = totalDuration }
        guard let previousEnergy = lastEnergy, let previousDuration = lastDuration else { return nil }
        let seconds = totalDuration - previousDuration
        guard seconds > 0.000_5 else { return nil }
        let level = (max(0, totalEnergy - previousEnergy) / seconds).squareRoot()
        lastLevel = level
        let windowStart = time - seconds
        if active {
            if level >= stopLevel {
                lastLoudEnd = time
                return nil
            }
            if let loud = lastLoudEnd, time - loud >= hangover {
                active = false
                candidateStart = nil
                return Transition(kind: .stopped, time: loud)
            }
            return nil
        }
        guard level >= startLevel else {
            candidateStart = nil
            return nil
        }
        let start = candidateStart ?? windowStart
        candidateStart = start
        lastLoudEnd = time
        guard time - start >= minimumSpeech else { return nil }
        active = true
        return Transition(kind: .started, time: start)
    }
}

/// One user → assistant exchange, measured on the phone.
struct VoiceTurn: Equatable {
    var userStart: Double
    var userEnd: Double?
    var assistantAudioStart: Double?
    /// Local arrival of the first assistant transcript fragment after the user stopped.
    var firstAssistantTranscript: Double?

    /// The latency a person feels: they stop talking → they hear the reply begin.
    var responseLatency: Double? {
        guard let end = userEnd, let audio = assistantAudioStart else { return nil }
        return audio - end
    }
}

/// Combines the microphone and incoming-audio detectors into turns.
struct TurnTracker {
    var microphone = AudioActivityDetector()
    /// Decoded assistant audio is clean (no room noise), so a lower threshold is safe.
    var assistant = AudioActivityDetector(startLevel: 0.01, stopLevel: 0.006, minimumSpeech: 0.04, hangover: 0.6)
    private(set) var current: VoiceTurn?
    private(set) var assistantSpeaking = false

    enum Event: Equatable {
        case userStarted(Double)
        case userStopped(VoiceTurn)
        case assistantStarted(VoiceTurn?)
        case assistantStopped(Double)
        /// The user talked over the assistant.
        case bargeIn(Double)
    }

    mutating func ingest(time: Double, microphoneEnergy: Double?, microphoneDuration: Double?,
                         remoteEnergy: Double?, remoteDuration: Double?) -> [Event] {
        var events: [Event] = []
        if let energy = microphoneEnergy, let duration = microphoneDuration,
           let transition = microphone.ingest(time: time, totalEnergy: energy, totalDuration: duration) {
            switch transition.kind {
            case .started:
                if assistantSpeaking { events.append(.bargeIn(transition.time)) }
                current = VoiceTurn(userStart: transition.time)
                events.append(.userStarted(transition.time))
            case .stopped:
                if var turn = current, turn.userEnd == nil {
                    turn.userEnd = transition.time
                    current = turn
                    events.append(.userStopped(turn))
                }
            }
        }
        if let energy = remoteEnergy, let duration = remoteDuration,
           let transition = assistant.ingest(time: time, totalEnergy: energy, totalDuration: duration) {
            switch transition.kind {
            case .started:
                assistantSpeaking = true
                if var turn = current, turn.userEnd != nil, turn.assistantAudioStart == nil {
                    turn.assistantAudioStart = transition.time
                    current = turn
                    events.append(.assistantStarted(turn))
                } else {
                    events.append(.assistantStarted(nil))
                }
            case .stopped:
                assistantSpeaking = false
                events.append(.assistantStopped(transition.time))
            }
        }
        return events
    }

    mutating func noteAssistantTranscript(at time: Double) {
        guard var turn = current, turn.userEnd != nil, turn.firstAssistantTranscript == nil,
              time >= turn.userEnd! else { return }
        turn.firstAssistantTranscript = time
        current = turn
    }
}
