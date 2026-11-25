import Foundation

/// Turns a wake phrase like "Hey Pixie" into the keyword line the wake-word model listens for
/// ("HH EY1 P IH1 K S IY0 @HEY_PIXIE"), using the model's pronouncing dictionary
/// (`lexicon.txt`, the CMU-style `en.phone` that `scripts/setup-model.sh` uses). This is what
/// lets the assistant be renamed without generating a keyword file: any name in the dictionary
/// works. Detection was only measured on "Hey Lobby" (recordings/positive), so other names may
/// need their own threshold.
enum WakePhrase {
    /// The label the model reports when it hears the phrase: "HEY_PIXIE".
    static func label(for phrase: String) -> String {
        words(phrase).joined(separator: "_")
    }

    static func words(_ phrase: String) -> [String] {
        phrase.uppercased()
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map(String.init)
    }

    /// One keyword line for sherpa-onnx, or an error naming the words the dictionary doesn't have.
    static func keywordLine(for phrase: String, lexicon: String) throws -> String {
        let wanted = words(phrase)
        guard !wanted.isEmpty else { throw WakeError.message("The wake phrase is empty.") }
        var sounds: [String: String] = [:]
        let needed = Set(wanted)
        lexicon.enumerateLines { line, stop in
            guard let space = line.firstIndex(of: " ") else { return }
            let word = String(line[..<space])
            // The first pronunciation wins, as in sherpa's own text2token.
            if needed.contains(word), sounds[word] == nil {
                sounds[word] = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
                if sounds.count == needed.count { stop = true }
            }
        }
        let missing = wanted.filter { sounds[$0] == nil }
        guard missing.isEmpty else {
            let list = missing.map { $0.capitalized }.joined(separator: ", ")
            throw WakeError.message("Can't listen for “\(phrase)”: no pronunciation for \(list).")
        }
        return wanted.compactMap { sounds[$0] }.joined(separator: " ") + " @" + label(for: phrase)
    }

    /// Reads `lexicon.txt` from the app bundle.
    static func keywordLine(for phrase: String, bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: "lexicon", withExtension: "txt") else {
            throw WakeError.message("Missing lexicon.txt. Run scripts/setup.sh before building.")
        }
        return try keywordLine(for: phrase, lexicon: String(contentsOf: url, encoding: .utf8))
    }
}
