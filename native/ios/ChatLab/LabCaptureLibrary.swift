import Foundation
import SwiftUI

extension CapturedCall {
    /// Two scenarios per call: the conversation as a user would see it, and the same call
    /// with every non-delta event inline (the debug lens).
    func scenarios(number: Int) -> [LabScenario] {
        let when = started?.formatted(date: .abbreviated, time: .shortened) ?? "unknown time"
        let length = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
        let about = isSample ? "A made-up call in the capture format" : "A real call"
        let base = "\(about) (\(source), \(length), \(when)), replayed at its own timing."
        let lines = lines
        return [
            LabScenario(id: "R\(number)", title: title,
                        lookFor: base + " Check the tool rows (web search, play_spotify, opening Spotify), the status line while \(Agent.name) looks things up, and how filler like \"One moment\" sits next to the answer.",
                        script: { CaptureReplay(lines: lines, rawEvents: false).steps }),
            LabScenario(id: "R\(number)e", title: "\(title) · events",
                        lookFor: base + " Every event sent and received appears inline between the messages; tap one to see its JSON.",
                        script: { CaptureReplay(lines: lines, rawEvents: true).steps }),
        ]
    }
}

/// Captured calls Chat Lab can replay: a made-up sample in the app, plus real ones in its
/// Documents folder (scripts/pull-call-captures.sh --lab copies them there, or add them
/// in the Files app or with Import). Real calls never go in the repo.
@MainActor
final class LabCaptureLibrary: ObservableObject {
    static let shared = LabCaptureLibrary()
    @Published private(set) var captures: [CapturedCall] = []

    var scenarios: [LabScenario] {
        captures.enumerated().flatMap { $1.scenarios(number: $0 + 1) }
    }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("call-captures", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = [documents, Self.folder].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension == "jsonl" }
        let real = files.compactMap(CapturedCall.load).sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sample: [CapturedCall] = bundled.compactMap(CapturedCall.load).map { capture in
            var capture = capture
            capture.isSample = true
            return capture
        }
        captures = sample + real
    }

    /// Copies picked files into the captures folder.
    func importFiles(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let target = Self.folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: url, to: target)
        }
        reload()
    }
}
