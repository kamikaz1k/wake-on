import XCTest
@testable import WakeOn

final class ObsidianNotesTests: XCTestCase {
    private var vault: URL!
    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    /// 2026-11-15, a Sunday.
    private let date = Date(timeIntervalSince1970: 1_794_700_800)

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    private func settings(_ name: String, _ json: String) throws {
        try json.write(to: vault.appendingPathComponent(".obsidian/\(name)"), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8)
    }

    func testDailyNoteNamesFollowMomentFormats() {
        XCTAssertEqual(ObsidianNotes.dailyName(format: "YYYY-MM-DD", date: date, calendar: utc), "2026-11-15")
        XCTAssertEqual(ObsidianNotes.dailyName(format: "YYYY/MM/dddd, MMMM Do", date: date, calendar: utc),
                       "2026/11/Sunday, November 15th")
        XCTAssertEqual(ObsidianNotes.dailyName(format: "[Day] D MMM YY", date: date, calendar: utc), "Day 15 Nov 26")
        let first = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01
        XCTAssertEqual(ObsidianNotes.dailyName(format: "Do", date: first, calendar: utc), "1st")
    }

    func testDailyNoteGoesToTheDailyNotesFolder() throws {
        let request = try XCTUnwrap(ObsidianNotes.request(title: "", text: "Call the dentist"))
        XCTAssertEqual(ObsidianNotes.path(for: request, vault: vault, date: date, calendar: utc), "2026-11-15.md")
        try settings("daily-notes.json", #"{"folder": "Journal/Daily/", "format": "YYYY-MM-DD ddd"}"#)
        XCTAssertEqual(ObsidianNotes.path(for: request, vault: vault, date: date, calendar: utc), "Journal/Daily/2026-11-15 Sun.md")
    }

    func testTitledNoteGoesWhereObsidianPutsNewNotes() throws {
        let request = try XCTUnwrap(ObsidianNotes.request(title: "Shopping list", text: "- milk"))
        XCTAssertEqual(ObsidianNotes.path(for: request, vault: vault), "Shopping list.md")
        try settings("app.json", #"{"newFileLocation": "folder", "newFileFolderPath": "Inbox"}"#)
        XCTAssertEqual(ObsidianNotes.path(for: request, vault: vault), "Inbox/Shopping list.md")
        try settings("app.json", #"{"newFileLocation": "current", "newFileFolderPath": "Inbox"}"#)
        XCTAssertEqual(ObsidianNotes.path(for: request, vault: vault), "Shopping list.md")
    }

    func testTitlesBecomeSafeFileNames() {
        XCTAssertEqual(ObsidianNotes.fileName("Ideas: work/home?"), "Ideas work home")
        XCTAssertEqual(ObsidianNotes.fileName("  #Gift [ideas]. "), "Gift ideas")
        XCTAssertEqual(ObsidianNotes.fileName("../../etc"), "etc", "no leaving the vault")
        XCTAssertNil(ObsidianNotes.request(title: "x", text: "  \n "))
    }

    func testSavingCreatesThenAppends() throws {
        let first = try XCTUnwrap(ObsidianNotes.request(title: "Shopping list", text: "- milk"))
        XCTAssertEqual(try ObsidianNotes.save(first, in: vault, date: date), "Shopping list.md")
        XCTAssertEqual(try read("Shopping list.md"), "- milk\n")
        try "# Shopping\n- eggs".write(to: vault.appendingPathComponent("Shopping list.md"), atomically: true, encoding: .utf8)
        try ObsidianNotes.save(try XCTUnwrap(ObsidianNotes.request(title: "Shopping list", text: "- bread")), in: vault, date: date)
        XCTAssertEqual(try read("Shopping list.md"), "# Shopping\n- eggs\n- bread\n")
    }

    func testSavingMakesTheDailyFolder() throws {
        try settings("daily-notes.json", #"{"folder": "Daily"}"#)
        let request = try XCTUnwrap(ObsidianNotes.request(title: "", text: "Parked on level 3"))
        let path = try ObsidianNotes.save(request, in: vault, date: date)
        XCTAssertTrue(path.hasPrefix("Daily/"))
        XCTAssertEqual(try read(path), "Parked on level 3\n")
    }

    func testOfferedOnlyWithAVault() throws {
        var config = LiveVoiceConfig()
        XCTAssertFalse(config.backendInstructions().contains("save_note"))
        config.notes = true
        XCTAssertTrue(config.backendInstructions().contains("save_note"))
        let responses = try XCTUnwrap((config.requestBody(sdp: "")["session"] as? [String: Any])?["delegation"] as? [String: Any])
        let tools = try XCTUnwrap((responses["responses"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "save_note" })
    }

    func testChainLabels() {
        let tool = ChatItem.Tool(name: "save_note", arguments: #"{"title":"Shopping list","text":"- milk"}"#, result: nil, state: .done)
        XCTAssertEqual(ChatToolSteps.label(tool), "Added to Shopping list")
        XCTAssertEqual(ChatToolSteps.summary([tool]), "Saved a note")
    }
}
