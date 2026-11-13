import Foundation
import SwiftUI

/// A real call recorded by Wake On (`CallCapture`: one JSON object per line with `t_ms`,
/// `source` and `event`), replayed in Chat Lab at its real timing.
struct CapturedCall: Identifiable {
    struct Line {
        var t: TimeInterval
        var source: String
        var event: [String: Any]
        var type: String { event["type"] as? String ?? "unknown" }
    }

    let id: String
    let url: URL
    let lines: [Line]
    var isSample = false

    var trigger: String {
        lines.first { $0.type == "app.call_started" }?.event["trigger"] as? String ?? ""
    }
    var started: Date? {
        (lines.first { $0.type == "app.call_started" }?.event["started"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    var duration: TimeInterval { lines.last?.t ?? 0 }

    /// What you said first, for the list.
    var title: String {
        let said = lines.filter { $0.type == "session.input_transcript.delta" }
            .compactMap { $0.event["delta"] as? String }.joined()
        let words = said.split(separator: " ").prefix(8).joined(separator: " ")
        return words.isEmpty ? "Lobby only" : words + (said.split(separator: " ").count > 8 ? "…" : "")
    }

    var source: String {
        switch trigger {
        case "wake_word": "Hey Lobby"
        case "app_intent_fast", "app_intent": "Action Button"
        case "in_app": "In app"
        default: trigger
        }
    }

    static func load(_ url: URL) -> CapturedCall? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").compactMap { line -> Line? in
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let event = json["event"] as? [String: Any] else { return nil }
            return Line(t: (json["t_ms"] as? Double ?? 0) / 1000, source: json["source"] as? String ?? "", event: event)
        }
        guard !lines.isEmpty else { return nil }
        return CapturedCall(id: url.deletingPathExtension().lastPathComponent, url: url, lines: lines)
    }
}

/// Turns a capture's events into timed transcript changes.
///
/// - Transcript deltas stream into messages. A new message starts when the speaker changes,
///   when a tool row or marker was added below the current one, or (for Lobby) when a looked-up
///   answer arrived since its last words, so the "One moment" filler and the answer are apart.
/// - Backend items become tool rows: web searches (with their query and the answer they led
///   to), function calls such as play_spotify (arguments as they stream, then our result), and
///   the app's own steps after the call: opening Spotify and media commands.
/// - Backend stages drive the status line; check-ins and the hang-up become markers.
struct CaptureReplay {
    /// Every step so far, timed from the trigger.
    var steps: [ChatStep] { script.steps }
    private var script = ChatScript()
    private let rawEvents: Bool
    private var taken = 0

    private struct Open { var id: String; var speaker: ChatItem.Speaker; var text: String }
    private var current: Open?
    /// Id of the last tool row or marker appended (raw event rows don't split messages).
    private var lastRow: String?
    private var lastUserWords: TimeInterval?
    private var replyTimingPending = false
    private var screenNoted = false
    private var answerArrived = false
    private var answerTimingPending = false
    private var tools: [String: (id: String, tool: ChatItem.Tool)] = [:]
    /// Web search rows per delegation, to attach the answer and its sources.
    private var searches: [String: [String]] = [:]

    /// Built up one event at a time, as a live call happens (see `LiveChat`).
    init(rawEvents: Bool = false) {
        self.rawEvents = rawEvents
        script.now = 0
    }

    /// A whole recorded call.
    init(lines: [CapturedCall.Line], rawEvents: Bool) {
        self.init(rawEvents: rawEvents)
        for line in lines { feed(line) }
        finish()
    }

    mutating func feed(_ line: CapturedCall.Line) {
        script.now = line.t
        if rawEvents { raw(line) }
        apply(line)
    }

    /// Marks whatever is still streaming as finished.
    mutating func finish() { finishMessage() }

    /// The steps added since the last call, to apply right away.
    mutating func takeNewSteps() -> [ChatStep] {
        let new = Array(script.steps[taken...])
        taken = script.steps.count
        return new
    }

    // MARK: - Events

    private mutating func apply(_ line: CapturedCall.Line) {
        let e = line.event
        switch line.type {
        case "app.call_started":
            script.run { $0.call.phase = "Connecting" }
            script.status("Connecting…")
        case "session.started":
            script.run { $0.call.phase = "Live" }
            script.status(nil)
            marker("Connected in \(seconds(line.t))")
        case "session.input_transcript.delta":
            say(.user, e["delta"] as? String ?? "", at: line.t)
        case "session.output_transcript.delta":
            say(.lobby, e["delta"] as? String ?? "", at: line.t)
        case "session.delegation.created":
            answerArrived = false
            script.status("Looking it up…")
        case "response.event":
            backend(e["event"] as? [String: Any] ?? [:], delegation: e["delegation_id"] as? String ?? "")
        case "session.commentary.append" where line.source == "client":
            marker("You went quiet · Lobby checks in")
        case "error":
            let message = (e["error"] as? [String: Any])?["message"] as? String ?? "Error"
            marker(message, .error)
        case "session.closed":
            finishMessage()
            script.run { $0.call.phase = "Ended" }
            script.status(nil)
        case "app.tool_call":
            let callID = e["call_id"] as? String ?? ""
            let action = e["action"] as? [String: Any] ?? [:]
            let place: ChatItem.Place? = if action["kind"] as? String == "map_show",
                let embed = action["embed_url"] as? String, let web = action["web_url"] as? String {
                ChatItem.Place(title: action["title"] as? String ?? "", embedURL: embed, webURL: web)
            } else { nil }
            updateTool(callID) {
                $0.result = e["output"] as? String
                $0.state = .done
                if let place { $0.place = place }
            }
        case "app.call_ended":
            finishMessage()
            marker(endNote(e, at: line.t))
        case "app.spotify_open":
            let title = e["title"] as? String ?? "Spotify"
            var tool = ChatItem.Tool(name: "open_in_spotify",
                                    arguments: [title, e["app_url"] as? String].compactMap { $0 }.joined(separator: "\n"),
                                    result: nil, state: .running)
            if let web = e["web_url"] as? String { tool.sources = [.init(title: title, url: web)] }
            addTool("spotify-open", tool)
        case "app.spotify_opened":
            let outcome = e["outcome"] as? String ?? ""
            let result = switch outcome {
            case "universal_link": "Opened in Spotify (open.spotify.com link)"
            case "app_link": "Opened in Spotify (spotify: link)"
            case "notification": "Wake On was in the background: posted a notification to tap"
            default: "Spotify didn't open"
            }
            updateTool("spotify-open") { $0.result = result; $0.state = outcome == "failed" ? .failed : .done }
        case "app.map_open":
            let title = e["title"] as? String ?? "Google Maps"
            let directions = e["mode"] as? String == "directions"
            var tool = ChatItem.Tool(name: "open_in_google_maps",
                                    arguments: [directions ? "Directions to \(title)" : title, e["web_url"] as? String]
                                        .compactMap { $0 }.joined(separator: "\n"),
                                    result: nil, state: .running)
            if let web = e["web_url"] as? String { tool.sources = [.init(title: title, url: web)] }
            addTool("map-open", tool)
        case "app.map_opened":
            let outcome = e["outcome"] as? String ?? ""
            let result = switch outcome {
            case "universal_link": "Opened in Google Maps (google.com/maps link)"
            case "app_link": "Opened in Google Maps (comgooglemaps: link)"
            case "web": "Google Maps isn't installed: opened it on the web"
            case "notification": "Wake On was in the background: posted a notification to tap"
            default: "Google Maps didn't open"
            }
            updateTool("map-open") { $0.result = result; $0.state = outcome == "failed" ? .failed : .done }
        case "app.screen":
            // What Lobby was told about the screen; the usual start (in view) isn't worth a line.
            let away = e["state"] as? String == "away"
            if away || screenNoted { marker(away ? "Screen not in view · Lobby answers in speech" : "Screen in view · Lobby can show things") }
            screenNoted = true
        case "app.media_command":
            let command = e["command"] as? String ?? ""
            addTool("media-\(line.t)", .init(name: "media_control", arguments: command,
                                             result: "Sent \(command) to whatever is playing", state: .done))
        default:
            break
        }
    }

    private mutating func backend(_ event: [String: Any], delegation: String) {
        let item = event["item"] as? [String: Any] ?? [:]
        let itemID = item["id"] as? String ?? event["item_id"] as? String ?? ""
        switch event["type"] as? String ?? "" {
        case "response.output_item.added":
            switch item["type"] as? String {
            case "reasoning": script.status("Thinking…")
            case "web_search_call":
                addTool(itemID, .init(name: "web_search", arguments: "", result: nil, state: .requested))
                searches[delegation, default: []].append(itemID)
            case "function_call":
                let name = item["name"] as? String ?? "function"
                addTool(itemID, .init(name: name, arguments: "", result: nil, state: .requested))
                // Our reply (app.tool_call) is keyed by call_id.
                if let callID = item["call_id"] as? String { tools[callID] = tools[itemID] }
                script.status(nil)
            default: break
            }
        case "response.web_search_call.searching":
            script.status("Searching the web…")
            updateTool(itemID) { $0.state = .running }
        case "response.function_call_arguments.delta":
            let delta = event["delta"] as? String ?? ""
            updateTool(itemID) {
                $0.arguments += delta
                if $0.name == ShowVisual.toolName {
                    $0.visual = ShowVisual.visual(fromArguments: $0.arguments, complete: false) ?? $0.visual
                }
            }
        case "response.output_item.done":
            switch item["type"] as? String {
            case "web_search_call":
                let action = item["action"] as? [String: Any] ?? [:]
                let queries = action["queries"] as? [String] ?? [action["query"] as? String].compactMap { $0 }
                updateTool(itemID) { $0.arguments = queries.joined(separator: "\n"); $0.state = .done }
            case "function_call":
                let raw = item["arguments"] as? String ?? ""
                if item["name"] as? String == ShowVisual.toolName {
                    // The page is shown by the row; the HTML would swamp the arguments.
                    let visual = ShowVisual.visual(fromArguments: raw, complete: true)
                    updateTool(itemID) { $0.visual = visual; $0.arguments = visual?.title ?? raw; $0.state = .running }
                } else {
                    let arguments = Self.pretty(raw)
                    updateTool(itemID) { $0.arguments = arguments; $0.state = .running }
                }
            case "message":
                let parts = item["content"] as? [[String: Any]] ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined()
                let sources = parts.flatMap { $0["annotations"] as? [[String: Any]] ?? [] }
                    .filter { $0["type"] as? String == "url_citation" }
                    .compactMap { a -> ChatItem.Source? in
                        guard let url = a["url"] as? String else { return nil }
                        return .init(title: a["title"] as? String ?? URL(string: url)?.host ?? url, url: url)
                    }
                for search in searches[delegation] ?? [] {
                    updateTool(search) {
                        if !text.isEmpty { $0.result = "Lobby was told: \(text)" }
                        $0.sources = sources
                    }
                }
            default: break
            }
        case "response.completed", "response.failed", "response.incomplete":
            script.status(nil)
            answerArrived = true
            answerTimingPending = true
        default:
            break
        }
    }

    // MARK: - Messages

    private mutating func say(_ speaker: ChatItem.Speaker, _ delta: String, at t: TimeInterval) {
        let continues = current.map {
            $0.speaker == speaker && lastRow == nil && !(speaker == .lobby && answerArrived)
        } ?? false
        if !continues {
            // Leading spaces and lone fragments like " " aren't worth a bubble of their own.
            guard delta.contains(where: { !$0.isWhitespace }) else { return }
            finishMessage()
            let id = script.id(speaker.rawValue)
            current = Open(id: id, speaker: speaker, text: "")
            lastRow = nil
            if speaker == .lobby { answerArrived = false }
            script.run { $0.append(ChatItem(id: id, kind: .message(speaker, text: "", state: .streaming))) }
        }
        guard var open = current else { return }
        open.text += delta
        current = open
        if speaker == .user { lastUserWords = t; replyTimingPending = true }
        let id = open.id, text = open.text.trimmingCharacters(in: .whitespaces)
        script.run { $0.update(id) { $0.kind = .message(speaker, text: text, state: .streaming) } }
        if speaker == .lobby, let heard = lastUserWords, replyTimingPending || answerTimingPending {
            let label = answerTimingPending && !replyTimingPending ? "Answer" : "Reply"
            let timing = "\(label) \(seconds(t - heard)) after you stopped"
            replyTimingPending = false
            answerTimingPending = false
            script.run { $0.update(id) { $0.timing = timing } }
        }
    }

    private mutating func finishMessage() {
        guard let open = current else { return }
        current = nil
        let text = open.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = open.id, speaker = open.speaker
        script.run { $0.update(id) { $0.kind = .message(speaker, text: text, state: .done) } }
    }

    // MARK: - Rows

    private mutating func marker(_ text: String, _ style: ChatItem.MarkerStyle = .system) {
        let id = script.id("marker")
        lastRow = id
        script.run { $0.append(ChatItem(id: id, kind: .marker(text, style))) }
    }

    private mutating func addTool(_ key: String, _ tool: ChatItem.Tool) {
        let id = script.id("tool")
        tools[key] = (id, tool)
        lastRow = id
        script.run { $0.append(ChatItem(id: id, kind: .tool(tool))) }
    }

    private mutating func updateTool(_ key: String, _ change: (inout ChatItem.Tool) -> Void) {
        guard var entry = tools[key] else { return }
        change(&entry.tool)
        // Keep every alias (item id and call_id) pointing at the latest state.
        for (alias, other) in tools where other.id == entry.id { tools[alias] = entry }
        let id = entry.id, tool = entry.tool
        script.run { $0.update(id) { $0.kind = .tool(tool) } }
    }

    /// The event itself, collapsed, for the events variant. Deltas would be hundreds of rows.
    private mutating func raw(_ line: CapturedCall.Line) {
        var type = line.type
        var body = line.event
        if type == "response.event", let nested = body["event"] as? [String: Any] {
            type = "backend · " + (nested["type"] as? String ?? "event")
        }
        if type.hasSuffix(".delta") || type == "app.milestone" { return }
        let direction: ChatItem.RawEvent.Direction = switch line.source {
        case "client": .sent
        case "app": .app
        default: .received
        }
        body = Self.withoutSecrets(body)
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        script.event(direction, type, json)
    }

    // MARK: - Helpers

    private func endNote(_ e: [String: Any], at t: TimeInterval) -> String {
        let length = Duration.seconds(t).formatted(.time(pattern: .minuteSecond))
        let why: String
        if e["spotify_pending"] as? Bool == true { why = "ended to play on Spotify" }
        else if e["map_pending"] as? Bool == true { why = "ended to open Google Maps" }
        else if let media = e["media_pending"] as? String { why = "ended to \(media) the music" }
        else {
            why = switch e["reason"] as? String ?? "" {
            case "close_requested": "ended after goodbye"
            case "user": "you ended it"
            case "network", "data_channel_closed": "connection lost"
            case let other: other
            }
        }
        return "Call ended · \(length) · \(why)"
    }

    private func seconds(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }

    /// Encrypted reasoning blobs are long and unreadable; drop them from what's shown.
    private static func withoutSecrets(_ value: [String: Any]) -> [String: Any] {
        value.reduce(into: [:]) { result, pair in
            guard pair.key != "encrypted_content" else { return }
            if let nested = pair.value as? [String: Any] { result[pair.key] = withoutSecrets(nested) }
            else { result[pair.key] = pair.value }
        }
    }

    private static func pretty(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A call's chat while it happens: each captured event goes through the same converter as
/// a saved call's, so the live view and the chat log afterwards look the same.
@MainActor
final class LiveChat {
    let transcript = ChatTranscript()
    private var replay = CaptureReplay()

    func add(_ line: CapturedCall.Line) {
        replay.feed(line)
        for step in replay.takeNewSteps() { step.apply(transcript) }
    }
}
