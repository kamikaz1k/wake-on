import BackgroundTasks
import Foundation

/// Writes the memory's summaries (see `Memory`). Nothing runs after a call that added no notes,
/// or while the start-of-call memory is short. Once it's getting long, iOS runs this overnight
/// while the iPhone charges; once it's over budget, it also runs right after the call.
enum MemoryJob {
    static let identifier = "com.kamikaz1k.wakeon.memory"
    /// Summaries per run, so a long backlog can't run up a bill in one go. About one per note
    /// (summaries merge two at a time), so this covers a backlog of over a hundred notes.
    static let maxPerRun = 128

    /// Before the app finishes launching (BGTaskScheduler's rule).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                let written = await run()
                VoiceSessionController.appLog("memory_job background written=\(written)")
                schedule()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks iOS for an overnight run: on power, with a network.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do { try BGTaskScheduler.shared.submit(request) } catch {
            VoiceSessionController.appLog("memory_job schedule_failed \(error)")
        }
    }

    /// After every call: nothing, an overnight run, or a run now.
    @MainActor
    static func afterCall(addedNotes: Bool) {
        guard addedNotes else { return }
        switch MemoryStore.shared.memory.need {
        case .none: break
        case .overnight: schedule()
        case .now:
            Task { @MainActor in
                let written = await run()
                VoiceSessionController.appLog("memory_job after_call written=\(written)")
            }
        }
    }

    private static var running = false

    /// Writes every summary that's ready, lowest level first. Returns how many.
    @MainActor
    static func run() async -> Int {
        guard !running, let credential = OpenAIKeyStore.load()?.key else { return 0 }
        running = true
        defer { running = false }
        var written = 0
        while written < maxPerRun, !Task.isCancelled, let next = MemoryStore.shared.memory.ready.first {
            let input = MemoryStore.shared.memory.summaryInput(level: next.level, index: next.index)
            do {
                let text = try await MemorySummarizer.summarize(input, credential: credential)
                // A note deleted meanwhile: its summary would bring it back.
                guard MemoryStore.shared.memory.summaryInput(level: next.level, index: next.index) == input else { continue }
                guard MemoryStore.shared.setSummary(level: next.level, index: next.index, text: text) else {
                    VoiceSessionController.appLog("memory_job refused bytes=\(text.utf8.count)")
                    break
                }
                written += 1
            } catch {
                VoiceSessionController.appLog("memory_job failed \(error)")
                break
            }
        }
        return written
    }
}

/// One summary line: with an OpenAI key straight from OpenAI, with an invite code from the
/// Pixie server (which holds the prompt, so it can't be used for anything else, and asks again
/// itself when a line is too long).
enum MemorySummarizer {
    static let openAI = URL(string: "https://api.openai.com/v1/responses")!

    static func summarize(_ lines: [String], credential: String) async throws -> String {
        if LobbyServer.isInviteCode(credential) {
            guard let server = LobbyServer.url else { throw VoiceError.message("No \(Agent.name) server in this build.") }
            return try await post(server.appendingPathComponent("v1/memory/summarize"), ["lines": lines], credential)
        }
        // Too long: say so and ask again, as OptMem does, instead of cutting the line.
        var attempts: [String] = []
        for _ in 0..<Memory.summaryTries {
            let text = try await post(openAI, Memory.summaryRequest(lines, attempts: attempts), credential)
            if Memory.tooLong(text) == nil { return text }
            attempts.append(text)
        }
        throw VoiceError.message("summary too long after \(Memory.summaryTries) tries")
    }

    private static func post(_ url: URL, _ body: [String: Any], _ credential: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        LobbyServer.authorize(&request, credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = outputText(json), !text.isEmpty else {
            throw VoiceError.message("summary failed: HTTP \(status)")
        }
        return text
    }

    /// The reply's text: the server's `text`, or a Responses API reply's output_text parts.
    static func outputText(_ json: [String: Any]) -> String? {
        if let text = json["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = parts.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
