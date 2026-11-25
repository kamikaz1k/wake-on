import XCTest
@testable import WakeOn

/// Pixie's memory (after OptMem): notes, the summary tree, what a call starts with, deleting.
final class MemoryTests: XCTestCase {
    private let callA = UUID()
    private let callB = UUID()

    private func memory(_ count: Int, call: UUID? = nil) -> Memory {
        var memory = Memory()
        for n in 0..<count {
            memory.add("note \(n)", call: call ?? callA, time: Date(timeIntervalSince1970: Double(n) * 86_400))
        }
        return memory
    }

    private func texts(_ units: [Memory.Unit]) -> [String] {
        units.map { unit in
            switch unit {
            case let .note(note): note.text
            case let .summary(summary): "S\(summary.level).\(summary.index)"
            }
        }
    }

    /// Writes every ready summary as "S<level>.<index>".
    private func summarizeAll(_ memory: inout Memory) {
        while let next = memory.ready.first {
            memory.setSummary(level: next.level, index: next.index, text: "S\(next.level).\(next.index)")
        }
    }

    func testNotesAreOneLineOfAtMost280Bytes() {
        var memory = Memory()
        XCTAssertNil(memory.add("  \n ", call: nil))
        XCTAssertEqual(memory.add("Ella's birthday\nis March 3", call: callA)?.text, "Ella's birthday is March 3")
        let long = memory.add(String(repeating: "é", count: 200), call: callA)!
        XCTAssertLessThanOrEqual(long.text.utf8.count, Memory.noteBytes)
        XCTAssertEqual(memory.notes.map(\.id), [0, 1])
    }

    func testShortMemoryIsAllNotesAndNeedsNoSummary() {
        let memory = memory(10)
        XCTAssertEqual(texts(memory.cover()), (0..<10).map { "note \($0)" })
        XCTAssertEqual(memory.need, .none, "Under the threshold: nothing runs")
    }

    func testSummariesMergeTwoAtATime() {
        XCTAssertTrue(memory(1).ready.isEmpty)
        XCTAssertEqual(memory(2).ready.map(\.level), [1])
        XCTAssertEqual(memory(2).ready.map(\.index), [0])
        XCTAssertEqual(memory(2).summaryInput(level: 1, index: 0).count, 2)
    }

    func testNeedGrowsWithTheStartOfCallMemory() {
        XCTAssertEqual(memory(Memory.summarizeAt).need, .none)
        XCTAssertEqual(memory(Memory.summarizeAt + 1).need, .overnight)
        XCTAssertEqual(memory(Memory.budget + 1).need, .now)
        var summarized = memory(Memory.budget + 1)
        summarizeAll(&summarized)
        XCTAssertEqual(summarized.need, .none)
    }

    func testOverBudgetKeepsTheNewestLines() {
        let memory = memory(45)
        let cover = memory.cover()
        XCTAssertEqual(cover.count, Memory.budget)
        XCTAssertEqual(texts(cover).last, "note 44")
        XCTAssertTrue(memory.callText()!.contains("Older notes left out"))
    }

    func testTreeFoldsUpAndTheBiggestOpensFirst() {
        var memory = memory(18)
        summarizeAll(&memory)
        // Notes 0-15 fold into one level-4 summary; 16 and 17 into a level-1 one.
        XCTAssertEqual(texts(memory.roots), ["S4.0", "S1.8"])
        XCTAssertEqual(texts(memory.cover(budget: 5)), ["S2.0", "S2.1", "S2.2", "S2.3", "S1.8"],
                       "The summary covering the most notes opens first, so lines stay even")
        XCTAssertEqual(texts(memory.cover(budget: 11)), (0...6).map { "S1.\($0)" } + (14...17).map { "note \($0)" },
                       "Among equals the newest opens first")
        XCTAssertEqual(memory.summaryInput(level: 2, index: 0), (0...3).map { Memory.text(.note(memory.notes[$0])) },
                       "Up to 16 notes are summarized from the notes, as in OptMem")
        XCTAssertEqual(memory.summaryInput(level: 4, index: 0).count, 16)
    }

    func testBigBlocksMergeTwoSummaries() {
        var memory = memory(32)
        summarizeAll(&memory)
        XCTAssertEqual(memory.summaryInput(level: 5, index: 0).count, 2)
        XCTAssertTrue(memory.summaryInput(level: 5, index: 0)[0].hasSuffix("S4.0"))
    }

    /// The fading rule matches OptMem's `cover()` (memo, Nov 2026): notes per line, oldest first.
    func testFadingCoverMatchesOptMem() {
        func sizes(_ count: Int, _ budget: Int) -> [Int] {
            var memory = memory(count)
            summarizeAll(&memory)
            return memory.cover(budget: budget, rule: .fading).map { unit in
                if case let .summary(summary) = unit { return Memory.span(level: summary.level, index: summary.index).count }
                return 1
            }
        }
        XCTAssertEqual(sizes(18, 5), [8, 4, 4, 1, 1])
        XCTAssertEqual(sizes(83, 40), Array(repeating: 4, count: 11) + Array(repeating: 2, count: 10) + Array(repeating: 1, count: 19))
        XCTAssertEqual(sizes(83, 12), [32, 16, 8, 8, 4, 4, 4, 2, 2, 1, 1, 1])
        XCTAssertEqual(sizes(280, 40), [32, 32] + Array(repeating: 16, count: 7) + Array(repeating: 8, count: 7)
                       + Array(repeating: 4, count: 6) + Array(repeating: 2, count: 6) + Array(repeating: 1, count: 12))
        XCTAssertEqual(sizes(30, 40), Array(repeating: 1, count: 30), "Under budget, every note word for word")
    }

    func testDeletingAChatDropsItsNotesAndTheirSummaries() {
        var memory = memory(16)
        memory.add("from B", call: callB)
        for n in 0..<7 { memory.add("more \(n)", call: callA) }
        summarizeAll(&memory)
        XCTAssertEqual(texts(memory.roots), ["S4.0", "S3.2"])
        XCTAssertEqual(memory.notes(fromCalls: [callB]).count, 1)
        memory.delete(calls: [callB])
        XCTAssertFalse(memory.notes.contains { $0.text == "from B" })
        XCTAssertEqual(texts(memory.roots), ["S4.0", "more 0", "S1.9", "S2.5"],
                       "Other blocks keep their summaries; its block is a note again until summarized")
        XCTAssertEqual(memory.ready.map(\.level), [1])
        XCTAssertEqual(memory.ready.map(\.index), [8])
    }

    func testDeleteAllKeepsNumbering() {
        var memory = memory(3)
        memory.deleteAll()
        XCTAssertTrue(memory.notes.isEmpty)
        XCTAssertNil(memory.callText())
        XCTAssertEqual(memory.add("new", call: nil)?.id, 3)
    }

    func testRecallMatchesEveryWordElseAny() {
        var memory = Memory()
        memory.add("Ella's birthday is March 3", call: nil)
        memory.add("Sam's birthday is June 9", call: nil)
        memory.add("The user lives in Toronto", call: nil)
        XCTAssertEqual(memory.recall("ella birthday").map(\.text), ["Ella's birthday is March 3"])
        XCTAssertEqual(memory.recall("birthday Toronto").count, 3, "No note has both: any word")
        XCTAssertEqual(Memory.recallText([]), "Nothing in memory matches.")
    }

    func testCallTextDatesEachLine() {
        var memory = Memory()
        memory.add("The user lives in Toronto", call: nil, time: Date(timeIntervalSince1970: 1_793_000_000))
        let text = memory.callText()!
        XCTAssertTrue(text.contains("- [Oct 26, 2026] The user lives in Toronto"), text)
    }

    func testCallsGetTheToolsAndTheMemory() {
        var config = LiveVoiceConfig()
        config.memory = "What you remember: the user lives in Toronto"
        let session = config.requestBody(sdp: "")["session"] as! [String: Any]
        XCTAssertTrue((session["instructions"] as! String).contains("lives in Toronto"))
        let responses = (session["delegation"] as! [String: Any])["responses"] as! [String: Any]
        XCTAssertTrue((responses["instructions"] as! String).contains("lives in Toronto"))
        XCTAssertTrue((responses["instructions"] as! String).contains("call remember"))
        let names = (responses["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("remember") && names.contains("recall") && names.contains("zoom"))
        XCTAssertTrue((session["instructions"] as! String).contains("Let me check my memory"))
    }

    func testZoomOpensASummaryDownToTheNotes() {
        var memory = memory(8)
        summarizeAll(&memory)
        XCTAssertTrue(memory.callText(budget: 1)!.contains("summary #0-7] S3.0"))
        XCTAssertEqual(memory.zoom("0-7").split(separator: "\n").map { $0.split(separator: "] ").last! }, ["S2.0", "S2.1"])
        XCTAssertTrue(memory.zoom("#0-3").contains("summary #2-3] S1.1"))
        XCTAssertEqual(memory.zoom("0-1").split(separator: "\n").count, 2)
        XCTAssertTrue(memory.zoom("0-1").contains("] note 1"))
        XCTAssertTrue(memory.zoom("3-9").hasPrefix("No summary"))
    }

    func testLongSummaryIsRefusedNotCut() {
        var memory = memory(2)
        XCTAssertFalse(memory.setSummary(level: 1, index: 0, text: String(repeating: "x", count: 300)))
        XCTAssertTrue(memory.summaries.isEmpty)
        XCTAssertEqual(Memory.tooLong(String(repeating: "x", count: 300)),
                       "Too long: 300 bytes, limit 280. Accented characters cost 2 bytes. Compress it further.")
        XCTAssertNil(Memory.tooLong(String(repeating: "é", count: 140)), "280 bytes fits")
        XCTAssertNotNil(Memory.tooLong(String(repeating: "é", count: 141)))
        XCTAssertTrue(memory.setSummary(level: 1, index: 0, text: "Both notes."))
    }

    func testSummaryRequestAndReply() {
        let body = Memory.summaryRequest(["a", "b"])
        XCTAssertEqual(body["model"] as? String, Memory.summaryModel)
        XCTAssertEqual((body["input"] as? [[String: Any]])?.first?["content"] as? String, "a\nb")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2000)
        let long = String(repeating: "x", count: 300)
        let retry = Memory.summaryRequest(["a", "b"], attempts: [long])["input"] as? [[String: Any]] ?? []
        XCTAssertEqual(retry.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(retry[1]["content"] as? String, long)
        XCTAssertTrue((retry[2]["content"] as? String ?? "").hasPrefix("Too long: 300 bytes"))
        XCTAssertEqual(MemorySummarizer.outputText(["text": " One line. "]), "One line.")
        let reply: [String: Any] = ["output": [["type": "reasoning"],
                                               ["content": [["type": "output_text", "text": "Merged."]]]]]
        XCTAssertEqual(MemorySummarizer.outputText(reply), "Merged.")
        XCTAssertNil(MemorySummarizer.outputText(["output": []]))
    }

    func testDeleteWordsMentionMemories() {
        XCTAssertEqual(MemoryDeleteWords.message(0), "This can't be undone.")
        XCTAssertTrue(MemoryDeleteWords.message(1).contains("1 thing \(Agent.name) remembered"))
        XCTAssertTrue(MemoryDeleteWords.message(3).contains("3 things"))
    }

    func testSummaryInstructionsMatchTheServer() throws {
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../server/src/index.js")
        guard let source = try? String(contentsOf: server, encoding: .utf8) else {
            throw XCTSkip("server source not reachable from this test run")
        }
        let joined = source.components(separatedBy: "\" +\n  \"").joined()
        XCTAssertTrue(joined.contains(Memory.summaryInstructions), "Keep the app and server prompts the same")
        XCTAssertTrue(source.contains("const SUMMARY_MODEL = \"\(Memory.summaryModel)\""), "Same summary model")
        XCTAssertTrue(source.contains("const SUMMARY_EFFORT = \"\(Memory.summaryEffort)\""), "Same reasoning effort")
    }
}
