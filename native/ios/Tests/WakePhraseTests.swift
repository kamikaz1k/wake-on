import XCTest
@testable import WakeOn

/// The wake phrase follows the assistant's name, built from the pronouncing dictionary.
final class WakePhraseTests: XCTestCase {
    private let lexicon = """
    HEY HH EY1
    LOBBY L AA1 B IY0
    PIXIE P IH1 K S IY0
    PIXIE P IH1 K S IY2
    """

    func testBuildsTheKeywordLineFromTheDictionary() throws {
        XCTAssertEqual(try WakePhrase.keywordLine(for: "Hey Pixie", lexicon: lexicon), "HH EY1 P IH1 K S IY0 @HEY_PIXIE")
        XCTAssertEqual(try WakePhrase.keywordLine(for: "hey lobby", lexicon: lexicon), "HH EY1 L AA1 B IY0 @HEY_LOBBY")
    }

    func testNamesMissingFromTheDictionaryAreReported() {
        XCTAssertThrowsError(try WakePhrase.keywordLine(for: "Hey Zorblax", lexicon: lexicon)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Zorblax"), error.localizedDescription)
        }
    }

    func testTheBundledDictionaryHasPixie() throws {
        XCTAssertEqual(try WakePhrase.keywordLine(for: "Hey Pixie", bundle: .main),
                       "HH EY1 P IH1 K S IY0 @HEY_PIXIE")
    }

    func testTheNameCanBeChangedWithoutASetting() {
        defer { UserDefaults.standard.removeObject(forKey: Agent.nameKey) }
        XCTAssertEqual(Agent.name, "Pixie")
        XCTAssertEqual(Agent.wakePhrase, "Hey Pixie")
        UserDefaults.standard.set("Nova", forKey: Agent.nameKey)
        XCTAssertEqual(Agent.wakePhrase, "Hey Nova")
        UserDefaults.standard.set("  ", forKey: Agent.nameKey)
        XCTAssertEqual(Agent.name, "Pixie")
    }
}
