import XCTest
@testable import WakeOn

/// Lobby's memory (after OptMem): notes, the summary tree, what a call starts with, deleting.
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

    func testSummariesWaitForAFullBlock() {
        XCTAssertTrue(memory(7).ready.isEmpty)
        XCTAssertEqual(memory(8).ready.map(\.level), [1])
        XCTAssertEqual(memory(8).ready.map(\.index), [0])
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

    func testTreeFoldsUpAndTheNewestOpensFirst() {
        var memory = memory(18)
        summarizeAll(&memory)
        // Blocks 0-7 and 8-15 summarized, then merged; 16 and 17 are still notes.
        XCTAssertEqual(texts(memory.roots), ["S2.0", "note 16", "note 17"])
        XCTAssertEqual(texts(memory.cover(budget: 5)), ["S1.0", "S1.1", "note 16", "note 17"])
        XCTAssertEqual(texts(memory.cover(budget: 11)), ["S1.0"] + (8...17).map { "note \($0)" },
                       "The newer half opens first")
        XCTAssertEqual(memory.summaryInput(level: 2, index: 0).count, 2)
    }

    func testDeletingAChatDropsItsNotesAndTheirSummaries() {
        var memory = memory(16)
        memory.add("from B", call: callB)
        for n in 0..<7 { memory.add("more \(n)", call: callA) }
        summarizeAll(&memory)
        XCTAssertEqual(texts(memory.roots), ["S2.0", "S1.2"])
        XCTAssertEqual(memory.notes(fromCalls: [callB]).count, 1)
        memory.delete(calls: [callB])
        XCTAssertFalse(memory.notes.contains { $0.text == "from B" })
        XCTAssertEqual(texts(memory.roots).first, "S2.0", "Other blocks keep their summaries")
        XCTAssertTrue(texts(memory.roots).contains("more 0"), "Its block is notes again until summarized")
        XCTAssertEqual(memory.ready.map(\.index), [2])
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
        XCTAssertTrue(names.contains("remember") && names.contains("recall"))
    }

    func testSummaryRequestAndReply() {
        let body = MemorySummarizer.body(["a", "b"])
        XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(body["input"] as? String, "a\nb")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(MemorySummarizer.outputText(["text": " One line. "]), "One line.")
        let reply: [String: Any] = ["output": [["type": "reasoning"],
                                               ["content": [["type": "output_text", "text": "Merged."]]]]]
        XCTAssertEqual(MemorySummarizer.outputText(reply), "Merged.")
        XCTAssertNil(MemorySummarizer.outputText(["output": []]))
    }

    func testDeleteWordsMentionMemories() {
        XCTAssertEqual(MemoryDeleteWords.message(0), "This can't be undone.")
        XCTAssertTrue(MemoryDeleteWords.message(1).contains("1 thing Lobby remembered"))
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
    }
}
