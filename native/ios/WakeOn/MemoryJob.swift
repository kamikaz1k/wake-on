import BackgroundTasks
import Foundation

/// Writes the memory's summaries (see `Memory`). Nothing runs after a call that added no notes,
/// or while the start-of-call memory is short. Once it's getting long, iOS runs this overnight
/// while the iPhone charges; once it's over budget, it also runs right after the call.
enum MemoryJob {
    static let identifier = "com.kamikaz1k.wakeon.memory"
    /// Summaries per run, so a long backlog can't run up a bill in one go.
    static let maxPerRun = 24

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
                MemoryStore.shared.setSummary(level: next.level, index: next.index, text: text)
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
/// Lobby server (which holds the prompt, so it can't be used for anything else).
enum MemorySummarizer {
    static let model = "gpt-5.4-mini"
    static let openAI = URL(string: "https://api.openai.com/v1/responses")!

    static func summarize(_ lines: [String], credential: String) async throws -> String {
        var request: URLRequest
        if LobbyServer.isInviteCode(credential) {
            guard let server = LobbyServer.url else { throw VoiceError.message("No Lobby server in this build.") }
            request = URLRequest(url: server.appendingPathComponent("v1/memory/summarize"))
            request.httpBody = try JSONSerialization.data(withJSONObject: ["lines": lines])
        } else {
            request = URLRequest(url: openAI)
            request.httpBody = try JSONSerialization.data(withJSONObject: body(lines))
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = outputText(json), !text.isEmpty else {
            throw VoiceError.message("summary failed: HTTP \(status)")
        }
        return text
    }

    static func body(_ lines: [String]) -> [String: Any] {
        ["model": model, "instructions": Memory.summaryInstructions,
         "input": lines.joined(separator: "\n"), "store": false, "max_output_tokens": 400,
         "reasoning": ["effort": "low"]]
    }

    /// The reply's text: the server's `text`, or a Responses API reply's output_text parts.
    static func outputText(_ json: [String: Any]) -> String? {
        if let text = json["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = parts.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
