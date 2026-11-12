import Foundation
import SwiftUI

/// A timed change to the transcript.
struct LabStep {
    var at: TimeInterval
    var apply: @MainActor (LabPlayer) -> Void
}

/// Replays a scenario script in real time. Every library page observes the same player, so
/// swiping between libraries shows the same moment of the same call.
@MainActor
final class LabPlayer: ObservableObject {
    @Published private(set) var items: [LabItem] = []
    /// Phase, mute and status changes count as updates too.
    @Published var call = LabCallState() { didSet { touched() } }
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    /// Bumped on every change, so renderers that copy data can cheaply detect updates.
    @Published private(set) var revision = 0
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

    private var steps: [LabStep] = []
    private var task: Task<Void, Never>?
    private var nextStep = 0
    private var recentUpdates: [Date] = []
    var duration: TimeInterval { steps.last?.at ?? 0 }

    func load(_ steps: [LabStep]) {
        self.steps = steps.sorted { $0.at < $1.at }
        restart()
    }

    func restart() {
        task?.cancel()
        extraTasks.forEach { $0.cancel() }
        extraTasks = []
        items = []
        call = LabCallState()
        progress = 0
        revision += 1
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
        turnCount += 1
        let index = turnCount
        var script = LabScript()
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

    // MARK: - Mutations used by scripts

    func append(_ item: LabItem) { items.append(item); touched() }

    func insert(_ item: LabItem, before id: String) {
        let index = items.firstIndex { $0.id == id } ?? items.endIndex
        items.insert(item, at: index)
        touched()
    }

    func update(_ id: String, _ change: (inout LabItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        touched()
    }

    func replaceAll(_ newItems: [LabItem]) { items = newItems; touched() }

    func setStatus(_ status: String?) { call.status = status }

    private func touched() {
        revision += 1
        let now = Date()
        recentUpdates.append(now)
        recentUpdates.removeAll { now.timeIntervalSince($0) > 1 }
        updatesPerSecond = recentUpdates.count
    }
}

// MARK: - Script building

/// Builds a scenario's steps on a running clock, so scripts read top to bottom like a call.
struct LabScript {
    private(set) var steps: [LabStep] = []
    var now: TimeInterval = 0.3
    private var counter = 0

    /// Keeps ids from on-demand turns apart from the scenario script's ids.
    var namespace = ""

    mutating func id(_ prefix: String) -> String { counter += 1; return "\(namespace)\(prefix)-\(counter)" }

    mutating func wait(_ seconds: TimeInterval) { now += seconds }

    mutating func run(_ apply: @escaping @MainActor (LabPlayer) -> Void) {
        steps.append(LabStep(at: now, apply: apply))
    }

    // Whole items

    mutating func marker(_ text: String, _ style: LabItem.MarkerStyle = .system) {
        let id = id("marker")
        run { $0.append(LabItem(id: id, kind: .marker(text, style))) }
    }

    mutating func status(_ text: String?) { run { $0.setStatus(text) } }

    mutating func event(_ direction: LabItem.RawEvent.Direction, _ type: String, _ body: String) {
        let id = id("event")
        run { $0.append(LabItem(id: id, kind: .event(.init(direction: direction, type: type, body: body)))) }
    }

    mutating func card(_ card: LabItem.Card) {
        let id = id("card")
        run { $0.append(LabItem(id: id, kind: .card(card))) }
    }

    /// A finished message, appended at once (history, or the wake-word burst).
    @discardableResult
    mutating func said(_ speaker: LabItem.Speaker, _ text: String, timing: String? = nil) -> String {
        let id = id(speaker.rawValue)
        run { $0.append(LabItem(id: id, kind: .message(speaker, text: text, state: .done), timing: timing)) }
        return id
    }

    /// Streams a message word by word. `wordsPerSecond` ~2.5 for your speech, faster for
    /// Lobby's transcript, which runs ahead of its audio.
    @discardableResult
    mutating func stream(_ speaker: LabItem.Speaker, _ text: String, wordsPerSecond: Double = 6,
                         timing: String? = nil, insertBefore: String? = nil, cutAfterWords: Int? = nil,
                         chunkCharacters: Int? = nil) -> String {
        let id = id(speaker.rawValue)
        // Built when the step runs, so its time matches the other rows.
        if let before = insertBefore {
            run { $0.insert(LabItem(id: id, kind: .message(speaker, text: "", state: .streaming)), before: before) }
        } else {
            run { $0.append(LabItem(id: id, kind: .message(speaker, text: "", state: .streaming))) }
        }
        // chunkCharacters splits into small pieces like real API deltas, so markdown is often half-written.
        let words = chunkCharacters.map { Self.chunks(text, size: $0) } ?? Self.tokens(text)
        var shown = ""
        for (index, word) in words.enumerated() {
            if let cut = cutAfterWords, index >= cut {
                run { $0.update(id) { $0.kind = .message(speaker, text: shown, state: .cutOff) } }
                return id
            }
            wait(1 / wordsPerSecond)
            shown += word
            let snapshot = shown
            run { $0.update(id) { $0.kind = .message(speaker, text: snapshot, state: .streaming) } }
        }
        wait(0.2)
        run { $0.update(id) { $0.kind = .message(speaker, text: text, state: .done); $0.timing = timing } }
        return id
    }

    /// Replaces a streamed message's text (transcription revising earlier words, B1).
    mutating func revise(_ id: String, _ speaker: LabItem.Speaker, to text: String) {
        run { $0.update(id) { $0.kind = .message(speaker, text: text, state: .done) } }
    }

    /// A tool row through its lifecycle (C1).
    @discardableResult
    mutating func tool(_ name: String, arguments: String, result: String?, sources: [LabItem.Source] = [],
                       runFor seconds: TimeInterval = 1.6, fails: Bool = false) -> String {
        let id = id("tool")
        let base = LabItem.Tool(name: name, arguments: arguments, result: nil, state: .requested)
        run { $0.append(LabItem(id: id, kind: .tool(base))) }
        wait(0.4)
        run { $0.update(id) { if case var .tool(tool) = $0.kind { tool.state = .running; $0.kind = .tool(tool) } } }
        wait(seconds)
        run {
            $0.update(id) {
                guard case var .tool(tool) = $0.kind else { return }
                tool.state = fails ? .failed : .done
                tool.result = result
                tool.sources = sources
                $0.kind = .tool(tool)
            }
        }
        return id
    }

    /// Splits text into fixed-size pieces, ignoring word boundaries.
    static func chunks(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == size { pieces.append(current); current = "" }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Splits text into words that keep their trailing spaces and line breaks.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" { tokens.append(current); current = "" }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
