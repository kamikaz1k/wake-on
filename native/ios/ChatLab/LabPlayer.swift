import Foundation
import SwiftUI


/// Replays a scenario script in real time. Every library page observes the same player, so
/// swiping between libraries shows the same moment of the same call.
@MainActor
final class LabPlayer: ChatTranscript {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    /// Updates applied in the last second (shown for G1).
    @Published private(set) var updatesPerSecond = 0

    /// Replay speed (1 = real time). Remembered across launches; changing it mid-replay
    /// carries on from the current step at the new rate.
    @Published var speed: Double = UserDefaults.standard.object(forKey: LabPlayer.speedKey) as? Double ?? 2 {
        didSet {
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            if isPlaying { play(from: nextStep) }
        }
    }
    static let speedKey = "chatlab.speed"
    static let speeds: [Double] = [1, 2, 4, 8]

    private var steps: [ChatStep] = []
    private var task: Task<Void, Never>?
    private var nextStep = 0
    private var recentUpdates: [Date] = []
    var duration: TimeInterval { steps.last?.at ?? 0 }

    func load(_ steps: [ChatStep]) {
        self.steps = steps.sorted { $0.at < $1.at }
        restart()
    }

    func restart() {
        task?.cancel()
        interrupted = []
        extraTasks.forEach { $0.cancel() }
        extraTasks = []
        items = []
        call = ChatCallState()
        progress = 0
        touched()
        play(from: 0)
    }

    func play(from index: Int = 0) {
        task?.cancel()
        isPlaying = true
        nextStep = index
        let start = Date()
        let steps = steps
        let base = index < steps.count ? (index > 0 ? steps[index - 1].at : 0) : 0
        let rate = max(speed, 0.1)
        let total = max(duration, 0.01)
        task = Task { @MainActor [weak self] in
            for position in index..<steps.count {
                let step = steps[position]
                let wait = (step.at - base) / rate - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled else { return }
                step.apply(self)
                self.nextStep = position + 1
                self.progress = min(1, step.at / total)
            }
            self?.isPlaying = false
            self?.progress = 1
        }
    }

    func stop() {
        task?.cancel()
        extraTasks.forEach { $0.cancel() }
        extraTasks = []
        isPlaying = false
    }

    private var extraTasks: [Task<Void, Never>] = []
    private var turnCount = 0

    /// Adds a spoken turn from you plus a streamed Lobby reply right now, on top of whatever
    /// is playing, so you can position the view first and then see how a library reacts.
    func newTurn() {
        // Talking over Lobby interrupts it (B3): cut off any reply that is still streaming.
        for index in items.indices {
            if case let .message(.lobby, text, .streaming) = items[index].kind {
                items[index].kind = .message(.lobby, text: text, state: .cutOff)
                interrupted.insert(items[index].id)
            }
        }
        touched()
        turnCount += 1
        let index = turnCount
        var script = ChatScript()
        script.namespace = "turn\(index)-"
        script.now = 0
        let question = LabText.questions[index % LabText.questions.count]
        script.stream(.user, question, wordsPerSecond: 2.5)
        script.wait(0.7)
        // Alternate short and long replies, so both "fits on screen" and "streams past" happen.
        let reply = index % 2 == 0 ? LabText.answers[index % LabText.answers.count] : LabText.long
        script.stream(.lobby, reply, wordsPerSecond: 6, timing: "Reply in 0.7 s")
        let steps = script.steps
        let start = Date()
        let rate = max(speed, 0.1)
        extraTasks.append(Task { @MainActor [weak self] in
            for step in steps {
                let wait = step.at / rate - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled else { return }
                step.apply(self)
            }
        })
    }

    override func touched() {
        super.touched()
        let now = Date()
        recentUpdates.append(now)
        recentUpdates.removeAll { now.timeIntervalSince($0) > 1 }
        updatesPerSecond = recentUpdates.count
    }
}

