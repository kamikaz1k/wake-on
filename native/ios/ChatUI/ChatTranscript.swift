import Foundation
import SwiftUI

/// A timed change to the transcript.
struct ChatStep {
    var at: TimeInterval
    var apply: @MainActor (ChatTranscript) -> Void
}

/// The rows of one conversation and the call around them, which `ChatTranscriptView` shows.
/// Scripts and capture replays change it through these mutations; Chat Lab's player replays
/// them over time, Wake On's chat log applies a finished call's steps all at once.
@MainActor
class ChatTranscript: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var call = ChatCallState() { didSet { touched() } }
    /// Bumped on every change, so renderers that copy data can cheaply detect updates.
    @Published var revision = 0
    /// Lobby replies you talked over: their later updates are ignored, like a real barge-in.
    var interrupted: Set<String> = []
    /// When set, rows appended now get this time instead of the clock's (a saved call).
    private var stepTime: Date?

    init() {}

    /// A finished call at once, each row stamped with when it really happened.
    convenience init(steps: [ChatStep], startedAt start: Date) {
        self.init()
        for step in steps.sorted(by: { $0.at < $1.at }) {
            stepTime = start.addingTimeInterval(step.at)
            step.apply(self)
        }
        stepTime = nil
    }

    func append(_ item: ChatItem) { items.append(stamped(item)); touched() }

    func insert(_ item: ChatItem, before id: String) {
        let index = items.firstIndex { $0.id == id } ?? items.endIndex
        items.insert(stamped(item), at: index)
        touched()
    }

    func update(_ id: String, _ change: (inout ChatItem) -> Void) {
        guard !interrupted.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        touched()
    }

    func replaceAll(_ newItems: [ChatItem]) { items = newItems.map(stamped); touched() }

    func setStatus(_ status: String?) { call.status = status }

    func touched() { revision += 1 }

    private func stamped(_ item: ChatItem) -> ChatItem {
        guard let stepTime else { return item }
        var item = item
        item.time = stepTime
        return item
    }
}

// MARK: - Script building

/// Builds a scenario's steps on a running clock, so scripts read top to bottom like a call.
struct ChatScript {
    private(set) var steps: [ChatStep] = []
    var now: TimeInterval = 0.3
    private var counter = 0

    /// Keeps ids from on-demand turns apart from the scenario script's ids.
    var namespace = ""

    mutating func id(_ prefix: String) -> String { counter += 1; return "\(namespace)\(prefix)-\(counter)" }

    mutating func wait(_ seconds: TimeInterval) { now += seconds }

    mutating func run(_ apply: @escaping @MainActor (ChatTranscript) -> Void) {
        steps.append(ChatStep(at: now, apply: apply))
    }

    // Whole items

    mutating func marker(_ text: String, _ style: ChatItem.MarkerStyle = .system) {
        let id = id("marker")
        run { $0.append(ChatItem(id: id, kind: .marker(text, style))) }
    }

    mutating func status(_ text: String?) { run { $0.setStatus(text) } }

    mutating func event(_ direction: ChatItem.RawEvent.Direction, _ type: String, _ body: String) {
        let id = id("event")
        run { $0.append(ChatItem(id: id, kind: .event(.init(direction: direction, type: type, body: body)))) }
    }

    mutating func card(_ card: ChatItem.Card) {
        let id = id("card")
        run { $0.append(ChatItem(id: id, kind: .card(card))) }
    }

    /// A finished message, appended at once (history, or the wake-word burst).
    @discardableResult
    mutating func said(_ speaker: ChatItem.Speaker, _ text: String, timing: String? = nil) -> String {
        let id = id(speaker.rawValue)
        run { $0.append(ChatItem(id: id, kind: .message(speaker, text: text, state: .done), timing: timing)) }
        return id
    }

    /// Streams a message word by word. `wordsPerSecond` ~2.5 for your speech, faster for
    /// Lobby's transcript, which runs ahead of its audio.
    @discardableResult
    mutating func stream(_ speaker: ChatItem.Speaker, _ text: String, wordsPerSecond: Double = 6,
                         timing: String? = nil, insertBefore: String? = nil, cutAfterWords: Int? = nil,
                         chunkCharacters: Int? = nil) -> String {
        let id = id(speaker.rawValue)
        // Built when the step runs, so its time matches the other rows.
        if let before = insertBefore {
            run { $0.insert(ChatItem(id: id, kind: .message(speaker, text: "", state: .streaming)), before: before) }
        } else {
            run { $0.append(ChatItem(id: id, kind: .message(speaker, text: "", state: .streaming))) }
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
    mutating func revise(_ id: String, _ speaker: ChatItem.Speaker, to text: String) {
        run { $0.update(id) { $0.kind = .message(speaker, text: text, state: .done) } }
    }

    /// A tool row through its lifecycle (C1).
    @discardableResult
    mutating func tool(_ name: String, arguments: String, result: String?, sources: [ChatItem.Source] = [],
                       runFor seconds: TimeInterval = 1.6, fails: Bool = false) -> String {
        let id = id("tool")
        let base = ChatItem.Tool(name: name, arguments: arguments, result: nil, state: .requested)
        run { $0.append(ChatItem(id: id, kind: .tool(base))) }
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
