import Foundation
import UIKit

/// Lobby's long-term memory, after OptMem (github.com/VictorTaelin/OptMem): an append-only log
/// of one-line notes Lobby writes during calls (`remember`), and a tree of one-line summaries
/// over them, so a call can start with the whole history in a few dozen lines: recent notes
/// word for word, older ones folded into summaries. `recall` still searches every note.
///
/// The tree is fixed by note number, as in OptMem: a level-1 summary merges two notes, and each
/// level up merges two summaries of the level below. A summary is written only once its block is
/// full, and only when the start-of-call memory is getting long (see `MemoryJob`), so short
/// calls cost nothing. Each note keeps the call it came from; deleting a chat can delete its
/// notes, and any summary that covered them is dropped and written again later.
struct Memory: Codable, Equatable {
    struct Note: Codable, Equatable, Identifiable {
        /// Its number in the log, never reused.
        var id: Int
        var time: Date
        var text: String
        /// The call (chat log id) it was written in.
        var call: UUID?
    }

    struct Summary: Codable, Equatable {
        /// 1 covers one block of notes; each level up covers twice as many.
        var level: Int
        /// Which block at its level: notes `span(level, index)`.
        var index: Int
        var text: String
        /// Its oldest and newest notes' times.
        var from: Date
        var to: Date
    }

    /// One line of the start-of-call memory.
    enum Unit: Equatable {
        case note(Note)
        case summary(Summary)
    }

    /// Oldest first.
    var notes: [Note] = []
    var summaries: [Summary] = []
    var nextID = 0

    /// Notes per level-1 summary. Two, as in OptMem: merging more at once made the model write
    /// past the limit and lose facts (see native/ios/scripts/memory-sim).
    static let block = 2
    /// OptMem's note size.
    static let noteBytes = 280
    /// Lines at the start of a call (about 2–3k tokens).
    static let budget = 40
    /// Summaries are written once the start-of-call memory, as compressed as it is now, is
    /// longer than this (overnight, see MemoryJob)...
    static let summarizeAt = 24
    /// ...or right after the call once it's longer than the budget.

    static func span(level: Int, index: Int) -> ClosedRange<Int> {
        let size = block << (level - 1)
        return index * size...(index * size + size - 1)
    }

    // MARK: Writing

    /// Adds a note, cut to `noteBytes`. Nil if it's empty.
    @discardableResult
    mutating func add(_ text: String, call: UUID?, time: Date = Date()) -> Note? {
        let line = Self.oneLine(text)
        guard !line.isEmpty else { return nil }
        let note = Note(id: nextID, time: time, text: line, call: call)
        nextID += 1
        notes.append(note)
        return note
    }

    /// Deletes notes, and every summary that covered one of them (written again later).
    mutating func delete(noteIDs: Set<Int>) {
        guard !noteIDs.isEmpty else { return }
        notes.removeAll { noteIDs.contains($0.id) }
        summaries.removeAll { summary in
            let span = Self.span(level: summary.level, index: summary.index)
            return noteIDs.contains { span.contains($0) }
        }
    }

    mutating func delete(calls: Set<UUID>) {
        delete(noteIDs: Set(notes(fromCalls: calls).map(\.id)))
    }

    mutating func deleteAll() {
        notes = []
        summaries = []
    }

    func notes(fromCalls calls: Set<UUID>) -> [Note] {
        notes.filter { $0.call.map(calls.contains) ?? false }
    }

    static func oneLine(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while line.utf8.count > noteBytes { line.removeLast() }
        return line
    }

    // MARK: Reading

    private func summary(_ level: Int, _ index: Int) -> Summary? {
        summaries.first { $0.level == level && $0.index == index }
    }

    private func notes(in span: ClosedRange<Int>) -> [Note] {
        var index = firstNote(atLeast: span.lowerBound), found: [Note] = []
        while index < notes.count, notes[index].id <= span.upperBound { found.append(notes[index]); index += 1 }
        return found
    }

    private func hasNotes(in span: ClosedRange<Int>) -> Bool {
        let index = firstNote(atLeast: span.lowerBound)
        return index < notes.count && notes[index].id <= span.upperBound
    }

    /// Notes are kept in id order, so blocks are found by binary search.
    private func firstNote(atLeast id: Int) -> Int {
        var low = 0, high = notes.count
        while low < high {
            let middle = (low + high) / 2
            if notes[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The smallest level whose first block holds every note number so far.
    private var topLevel: Int {
        var level = 1
        while Self.span(level: level, index: 0).upperBound < nextID - 1 { level += 1 }
        return level
    }

    /// The fewest lines that cover the notes in this block: its summary, else its halves'.
    private func units(_ level: Int, _ index: Int) -> [Unit] {
        guard !notes(in: Self.span(level: level, index: index)).isEmpty else { return [] }
        if let summary = summary(level, index) { return [.summary(summary)] }
        return children(level, index)
    }

    /// What a summary opens into: its notes, or its two halves.
    private func children(_ level: Int, _ index: Int) -> [Unit] {
        if level == 1 { return notes(in: Self.span(level: 1, index: index)).map(Unit.note) }
        return units(level - 1, index * 2) + units(level - 1, index * 2 + 1)
    }

    /// Every note, as compressed as the summaries so far allow, oldest first.
    var roots: [Unit] { notes.isEmpty ? [] : units(topLevel, 0) }

    /// How the start-of-call memory spends its lines.
    enum CoverRule: String { case fading, even }
    static let coverRule = CoverRule.even

    /// What a call starts with, at most `budget` lines. Over budget, the oldest lines are left
    /// out (still found by `recall`) until the summaries catch up.
    func cover(budget: Int = Memory.budget, rule: CoverRule = Memory.coverRule) -> [Unit] {
        switch rule {
        case .even: evenCover(budget)
        case .fading: fadingCover(budget)
        }
    }

    /// OptMem's rule: detail fades with age. A line may cover at most `alpha` times as many
    /// notes as its oldest note is old (in notes saved since), with the smallest `alpha` that
    /// fits the budget; lines left over open the newest summaries.
    private func fadingCover(_ budget: Int) -> [Unit] {
        if notes.count <= budget { return notes.map(Unit.note) }
        func tiles(_ alpha: Double) -> [Unit] {
            func walk(_ level: Int, _ index: Int) -> [Unit] {
                let span = Self.span(level: level, index: index)
                guard hasNotes(in: span) else { return [] }
                if span.upperBound < nextID, Double(span.count) <= alpha * Double(nextID - span.lowerBound),
                   let summary = summary(level, index) {
                    return [.summary(summary)]
                }
                if level == 1 { return notes(in: span).map(Unit.note) }
                return walk(level - 1, index * 2) + walk(level - 1, index * 2 + 1)
            }
            return walk(topLevel, 0)
        }
        var lines = tiles(1)
        if lines.count < budget {
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if tiles(middle).count > budget { low = middle } else { high = middle }
            }
            lines = tiles(high)
        }
        // Sizes jump in powers of two, so spend what's left on the newest.
        while let position = lines.indices.last(where: { position in
            guard case let .summary(summary) = lines[position] else { return false }
            return lines.count - 1 + children(summary.level, summary.index).count <= budget
        }), case let .summary(summary) = lines[position] {
            lines.replaceSubrange(position...position, with: children(summary.level, summary.index))
        }
        return Array(lines.suffix(budget))
    }

    /// Even: the roots, then summaries opened up while it fits the budget, the one covering the
    /// most notes first (the newest of those), so no line has to hold far more than the others.
    /// Opening only the newest first, without OptMem's limit by age, left the oldest 32 notes in
    /// one line and lost their details (see memory-sim).
    private func evenCover(_ budget: Int) -> [Unit] {
        var lines = roots
        while true {
            var best: (position: Int, level: Int, inside: [Unit])?
            for position in lines.indices {
                guard case let .summary(summary) = lines[position], summary.level >= (best?.level ?? 0) else { continue }
                let inside = children(summary.level, summary.index)
                if lines.count - 1 + inside.count <= budget { best = (position, summary.level, inside) }
            }
            guard let best else { break }
            lines.replaceSubrange(best.position...best.position, with: best.inside)
        }
        return Array(lines.suffix(budget))
    }

    /// No summary needed yet; one overnight; or one right after this call.
    enum Need: Equatable { case none, overnight, now }

    var need: Need {
        guard !ready.isEmpty else { return .none }
        let count = roots.count
        if count > Self.budget { return .now }
        return count > Self.summarizeAt ? .overnight : .none
    }

    /// Summaries that can be written now, lowest level first: a full block with no summary
    /// whose halves are summarized (or empty).
    var ready: [(level: Int, index: Int)] {
        var found: [(Int, Int)] = []
        var level = 1
        while Self.span(level: level, index: 0).upperBound < nextID {
            var index = 0
            while Self.span(level: level, index: index).upperBound < nextID {
                let span = Self.span(level: level, index: index)
                if summary(level, index) == nil, !notes(in: span).isEmpty,
                   level == 1 || [index * 2, index * 2 + 1].allSatisfy({ half in
                       summary(level - 1, half) != nil || notes(in: Self.span(level: level - 1, index: half)).isEmpty
                   }) {
                    found.append((level, index))
                }
                index += 1
            }
            level += 1
        }
        return found
    }

    /// The lines a summary is written from, oldest first.
    func summaryInput(level: Int, index: Int) -> [String] {
        children(level, index).map(Self.text)
    }

    /// Saves a summary. A line over `noteBytes` is refused, never cut (cutting lost facts): ask
    /// again with `tooLong`.
    @discardableResult
    mutating func setSummary(level: Int, index: Int, text: String) -> Bool {
        let covered = notes(in: Self.span(level: level, index: index))
        guard let first = covered.first, let last = covered.last else { return false }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, Self.tooLong(line) == nil else { return false }
        summaries.removeAll { $0.level == level && $0.index == index }
        summaries.append(Summary(level: level, index: index, text: line, from: first.time, to: last.time))
        return true
    }

    /// Notes with every word of the query (else any word), newest first.
    func recall(_ query: String, limit: Int = 12) -> [Note] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return Array(notes.suffix(limit).reversed()) }
        let all = notes.filter { note in words.allSatisfy { note.text.lowercased().contains($0) } }
        let found = all.isEmpty ? notes.filter { note in words.contains { note.text.lowercased().contains($0) } } : all
        return Array(found.suffix(limit).reversed())
    }

    // MARK: Words for the models

    private static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMM d, yyyy"
        return format
    }()

    static func text(_ unit: Unit) -> String {
        switch unit {
        case let .note(note): "[\(day.string(from: note.time))] \(note.text)"
        case let .summary(summary):
            "[\(day.string(from: summary.from)) to \(day.string(from: summary.to)), summary] \(summary.text)"
        }
    }

    /// The start-of-call memory for both models' instructions; nil when there's none.
    func callText(budget: Int = Memory.budget) -> String? {
        let lines = cover(budget: budget)
        guard !lines.isEmpty else { return nil }
        let left = roots.count > lines.count ? "(Older notes left out; recall finds them.)\n" : ""
        return "What you remember about the user from earlier calls, oldest first (summaries cover older notes):\n"
            + left + lines.map { "- " + Self.text($0) }.joined(separator: "\n")
    }

    static func recallText(_ notes: [Note]) -> String {
        notes.isEmpty ? "Nothing in memory matches."
            : notes.map { "[\(day.string(from: $0.time))] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Tools

    static let rememberTool = "remember"
    static let recallTool = "recall"

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "name": rememberTool,
            "description": "Save one short fact about the user to your long-term memory, so you know it in later calls.",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "note": [
                        "type": "string",
                        "description": "One line, with what makes it useful later, e.g. \"Ella's birthday is March 3\" or \"The user moved to Toronto in November 2026\".",
                    ],
                ],
                "required": ["note"],
                "additionalProperties": false,
            ] as [String: Any],
        ],
        [
            "type": "function",
            "name": recallTool,
            "description": "Search everything you noted about the user in earlier calls, including notes older than what you remember at the start of the call.",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A few words to look for, e.g. \"birthday Ella\"."],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ] as [String: Any],
        ],
    ]

    static let delegationInstructions = """
    You have a long-term memory of the user. When the user asks you to remember something, call \
    remember with it, then confirm in a few words; the call goes on. Also call remember, without \
    being asked, when the conversation shows a lasting fact about the user that would help in \
    later calls: people in their life, where they live, their preferences, plans and decisions. \
    Never for small talk or for what you looked up. Remembering is not saving to their notes: \
    a request to note something down or add to a list goes to their notes, if you can. When a \
    question is about an earlier conversation and the answer isn't in what you remember, call recall.
    """

    static let voiceInstructions = """
    Delegate requests to remember something, and questions about earlier conversations whose \
    answer you don't know from what you remember. To forget something, the user deletes it in \
    Pixie under Settings, Memory.
    """

    // MARK: Summaries

    /// Writes the summaries (with an OpenAI key; the server uses the same for an invite code).
    static let summaryModel = "gpt-6.2-sol"
    static let summaryEffort = "medium"
    /// Tries per summary: the first, then up to two after "too long".
    static let summaryTries = 3

    /// How a summary is written (here for an OpenAI key, on the server for an invite code).
    /// After OptMem's merge prompt.
    static let summaryInstructions = """
    You compress a voice assistant's memory of its user. Compress the memories you're given, \
    oldest first, into one line of at most 280 bytes. Keep what has lasting effect, drop what \
    does not. Invent nothing. When they disagree, the later one wins. Reply with the line only.
    """

    /// What to say back when a summary is over the limit (as OptMem does); nil when it fits.
    static func tooLong(_ text: String) -> String? {
        let bytes = text.utf8.count
        guard bytes > noteBytes else { return nil }
        return "Too long: \(bytes) bytes, limit \(noteBytes). Accented characters cost 2 bytes. Compress it further."
    }

    /// A Responses API request for one summary. `attempts` are earlier replies that were too long.
    static func summaryRequest(_ lines: [String], attempts: [String] = [],
                               model: String = summaryModel, effort: String = summaryEffort) -> [String: Any] {
        var input: [[String: Any]] = [["role": "user", "content": lines.joined(separator: "\n")]]
        for attempt in attempts {
            input.append(["role": "assistant", "content": attempt])
            input.append(["role": "user", "content": tooLong(attempt) ?? "Compress it further."])
        }
        // Room for reasoning: at 400, low reasoning sometimes left no text at all.
        return ["model": model, "instructions": summaryInstructions, "input": input, "store": false,
                "max_output_tokens": 2000, "reasoning": ["effort": effort]]
    }
}

/// The memory on this iPhone, in Application Support/memory.json.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var memory = Memory()
    private let url: URL
    /// As for chat logs: false while the file is there but can't be read yet (before the first
    /// unlock); nothing is written then, so the saved memory is never replaced.
    private var loaded = false
    /// Notes written before the file could be read.
    private var waiting: [(String, UUID?, Date)] = []

    init(url: URL = MemoryStore.defaultURL) {
        self.url = url
        loaded = load()
    }

    nonisolated static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("memory.json")
    }

    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url) else { return false }
        if let saved = try? JSONDecoder().decode(Memory.self, from: data) {
            memory = saved
        } else {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        return true
    }

    private func ensureLoaded() -> Bool {
        if loaded { return true }
        loaded = load()
        guard loaded else { return false }
        for (text, call, time) in waiting { memory.add(text, call: call, time: time) }
        waiting = []
        return true
    }

    private func change(_ edit: (inout Memory) -> Void) {
        guard ensureLoaded() else { return }
        edit(&memory)
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func remember(_ text: String, call: UUID?) -> Memory.Note? {
        guard ensureLoaded() else {
            waiting.append((text, call, Date()))
            return Memory.Note(id: -1, time: Date(), text: Memory.oneLine(text), call: call)
        }
        var note: Memory.Note?
        change { note = $0.add(text, call: call) }
        return note
    }

    func delete(noteIDs: Set<Int>) { change { $0.delete(noteIDs: noteIDs) } }
    func delete(calls: Set<UUID>) { change { $0.delete(calls: calls) } }
    func deleteAll() { change { $0.deleteAll() } }
    @discardableResult
    func setSummary(level: Int, index: Int, text: String) -> Bool {
        var saved = false
        change { saved = $0.setSummary(level: level, index: index, text: text) }
        return saved
    }

    func noteCount(fromCalls calls: Set<UUID>) -> Int {
        _ = ensureLoaded()
        return memory.notes(fromCalls: calls).count
    }

    var callText: String? {
        _ = ensureLoaded()
        return memory.callText()
    }
}
