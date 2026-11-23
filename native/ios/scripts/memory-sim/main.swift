// Simulates Lobby's memory filling up over months of calls, with the app's own `Memory` code
// (copied out of WakeOn/Memory.swift by run.sh) and real summaries from OpenAI.
//
//   run.sh <out-dir> [lobby|eager|never]
//
// lobby: the app's policy (MemoryJob): nothing after a call that saved no note, an overnight run
//        once the start-of-call memory passes 24 lines, a run right after the call past 40.
// eager: summarize everything ready after every call that saved a note (the cost ceiling).
// never: no summaries (the memory a phone would have before its first run).
//
// At days 30, 60 and the last day, a model answers quiz.txt from the start-of-call memory
// alone (no recall) and a second model grades the answers.
import Foundation

let args = CommandLine.arguments
let folder = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let policy = args.count > 3 ? args[3] : "lobby"
let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
let model = "gpt-5.4-mini"
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: Inputs

struct Call { var day: Int; var notes: [String] }
var calls: [Call] = []
for line in try String(contentsOf: folder.appendingPathComponent("persona.txt"), encoding: .utf8).split(separator: "\n") {
    if line.hasPrefix("#") && !line.hasPrefix("## ") { continue }
    if line.hasPrefix("## day ") { calls.append(Call(day: Int(line.dropFirst(7))!, notes: [])) }
    else if !line.trimmingCharacters(in: .whitespaces).isEmpty { calls[calls.count - 1].notes.append(String(line)) }
}

struct Question { var q: String; var expected: String; var day: Int; var kind: String }
let quiz: [Question] = try String(contentsOf: folder.appendingPathComponent("quiz.txt"), encoding: .utf8)
    .split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return Question(q: parts[0], expected: parts[1], day: Int(parts[2])!, kind: parts[3])
    }

let start = ISO8601DateFormatter().date(from: "2026-08-01T18:00:00Z")!
func date(_ day: Int) -> Date { start.addingTimeInterval(Double(day) * 86400) }

// MARK: OpenAI

var tokens = ["summary": 0, "quiz": 0]
var empties = 0
var requests = ["summary": 0, "quiz": 0]

func respond(_ body: [String: Any], kind: String) async throws -> String {
    let json = try await respondJSON(body, kind: kind)
    let parts = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
    return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

func respondJSON(_ body: [String: Any], kind: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "openai", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
    }
    tokens[kind, default: 0] += (json["usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0
    requests[kind, default: 0] += 1
    let types = (json["output"] as? [[String: Any]] ?? []).flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String } + [$0["type"] as? String ?? ""] }
    if !types.contains("output_text") && !types.contains("function_call") {
        empties += 1
        FileHandle.standardError.write("empty \(kind) reply: status=\(json["status"] ?? "") \(json["incomplete_details"] ?? "") usage=\(json["usage"] ?? "")\n".data(using: .utf8)!)
    }
    return json
}

/// SUMMARY_PROMPT (a file) tries another prompt; otherwise the app's.
let summaryPrompt = ProcessInfo.processInfo.environment["SUMMARY_PROMPT"]
    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? Memory.summaryInstructions

/// The same request as MemorySummarizer.body in the app.
var rawBytes: [Int] = []
func summarize(_ lines: [String]) async throws -> String {
    let text = try await respondRaw(lines)
    rawBytes.append(text.utf8.count)
    return text
}
func respondRaw(_ lines: [String]) async throws -> String {
    try await respond(["model": model, "instructions": summaryPrompt,
                       "input": lines.joined(separator: "\n"), "store": false, "max_output_tokens": 400,
                       "reasoning": ["effort": "low"]], kind: "summary")
}

func schema(_ name: String, _ item: [String: Any]) -> [String: Any] {
    ["format": ["type": "json_schema", "name": name, "strict": true,
                "schema": ["type": "object", "additionalProperties": false, "required": ["items"],
                           "properties": ["items": ["type": "array", "items": item]]]]]
}

/// Answers from the start-of-call memory; with `recall`, the model may also search every note
/// with the app's recall tool, as Lobby can in a call.
func ask(_ questions: [Question], memory text: String, recall: Bool) async throws -> [String] {
    // With recall, one question per request in plain text, as in a call (a JSON reply format
    // over many questions at once kept the model from searching at all).
    if recall {
        var answers: [String] = []
        for question in questions { answers.append(try await askOne(question.q, memory: text)) }
        return answers
    }
    let item: [String: Any] = ["type": "string"]
    var input: [[String: Any]] = [["role": "user", "content":
        questions.enumerated().map { "\($0.offset + 1). \($0.element.q)" }.joined(separator: "\n")]]
    var body: [String: Any] = [
        "model": model, "store": false, "reasoning": ["effort": "low"],
        "instructions": "You are Lobby, a voice assistant. Answer each question about the user in a few words, from what you remember" + (recall ? " or find with recall (search as needed)" : " only") + ". If you can't find it, answer \"don't know\".\n\n" + text,
        "text": schema("answers", item),
    ]
    if recall { body["tools"] = [Memory.tools[1]] }
    for _ in 0..<4 {
        body["input"] = input
        let json = try await respondJSON(body, kind: "quiz")
        let output = json["output"] as? [[String: Any]] ?? []
        let calls = output.filter { $0["type"] as? String == "function_call" }
        if calls.isEmpty {
            let parts = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            let reply = parts.compactMap { $0["text"] as? String }.joined()
            let items = ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])?["items"] as? [String] ?? []
            return questions.indices.map { $0 < items.count ? items[$0] : "" }
        }
        for call in calls {
            input.append(call)
            let arguments = (try? JSONSerialization.jsonObject(with: Data((call["arguments"] as? String ?? "{}").utf8))) as? [String: Any]
            let query = arguments?["query"] as? String ?? ""
            recalls += 1
            input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "",
                          "output": Memory.recallText(memory.recall(query))])
        }
    }
    return questions.map { _ in "" }
}
var recalls = 0

func askOne(_ question: String, memory text: String) async throws -> String {
    var input: [[String: Any]] = [["role": "user", "content": question]]
    let body: [String: Any] = [
        "model": model, "store": false, "reasoning": ["effort": "low"], "tools": [Memory.tools[1]],
        "instructions": "You are Lobby, a voice assistant. Answer the user's question about themselves in a few words. " + Memory.delegationInstructions + " If you still can't find it, say you don't know.\n\n" + text,
    ]
    for _ in 0..<4 {
        var request = body
        request["input"] = input
        let output = try await respondJSON(request, kind: "quiz")["output"] as? [[String: Any]] ?? []
        let calls = output.filter { $0["type"] as? String == "function_call" }
        if calls.isEmpty {
            return output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
        }
        for call in calls {
            input.append(call)
            let arguments = (try? JSONSerialization.jsonObject(with: Data((call["arguments"] as? String ?? "{}").utf8))) as? [String: Any]
            recalls += 1
            input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "",
                          "output": Memory.recallText(memory.recall(arguments?["query"] as? String ?? ""))])
        }
    }
    return ""
}

func grade(_ questions: [Question], _ answers: [String]) async throws -> [String] {
    let item: [String: Any] = ["type": "string", "enum": ["right", "partly", "stale", "wrong", "missing"]]
    let input = questions.indices.map { "\($0 + 1). Q: \(questions[$0].q)\nExpected: \(questions[$0].expected)\nGot: \(answers[$0])" }
    let text = try await respond([
        "model": model, "store": false, "reasoning": ["effort": "low"],
        "instructions": "Grade each answer against the expected one. right: gets the main fact the question asks for (extra detail in the expected answer, in parentheses or after a semicolon, is optional). partly: half of a two-part answer. stale: gives an answer that was true earlier but changed (the expected answer says what it changed from). wrong: otherwise incorrect. missing: says it doesn't know.",
        "input": input.joined(separator: "\n\n"), "text": schema("grades", item),
    ], kind: "quiz")
    return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["items"] as? [String] ?? []
}

// MARK: The run

var memory = Memory()
var log: [String] = ["day\tcall\tsaved\tnotes\tsummaries\troots\tcover\tleft_out\tchars\tneed\tran\twritten"]
var overnight = false
var checkpoints = [30, 60, calls.last!.day]
var report = "# Memory simulation: \(policy)\n\n"

func runJob() async throws -> Int {
    var written = 0
    while written < 24, let next = memory.ready.first {
        let input = memory.summaryInput(level: next.level, index: next.index)
        memory.setSummary(level: next.level, index: next.index, text: try await summarize(input))
        written += 1
    }
    return written
}

func quizAt(_ day: Int, final: Bool) async throws {
    // Facts that change later have their final answer in quiz.txt, so they're asked only at the end.
    let known = quiz.filter { $0.day <= day && (final || $0.kind != "update") }
    let text = memory.callText() ?? ""
    try text.write(to: out.appendingPathComponent("call-start-day\(day).txt"), atomically: true, encoding: .utf8)
    let plain = try await ask(known, memory: text, recall: false)
    let plainGrades = try await grade(known, plain)
    recalls = 0
    let searched = try await ask(known, memory: text, recall: true)
    let searchedGrades = try await grade(known, searched)
    let score = { (grades: [String]) in grades.filter { $0 == "right" }.count }
    report += "## Day \(day): \(score(plainGrades)) of \(known.count) right from memory alone, \(score(searchedGrades)) with recall (\(recalls) searches)\n\n"
    report += "\(memory.notes.count) notes, \(memory.summaries.count) summaries, \(memory.cover().count) lines at call start (\(text.count) characters).\n\n"
    report += "| kind | question | memory alone | with recall |\n|---|---|---|---|\n"
    for index in known.indices {
        let a = index < plainGrades.count ? plainGrades[index] : "?", b = index < searchedGrades.count ? searchedGrades[index] : "?"
        report += "| \(known[index].kind) | \(known[index].q) | \(plain[index]) (\(a)) | \(searched[index]) (\(b)) |\n"
    }
    report += "\n"
    print("day \(day): \(score(plainGrades))/\(known.count) memory alone, \(score(searchedGrades)) with recall")
}

var lastDay = -1
for (number, call) in calls.enumerated() {
    var ran = "", written = 0
    if call.day > lastDay, overnight {
        written += try await runJob(); ran = "overnight"; overnight = false
    }
    lastDay = call.day
    for note in call.notes { memory.add(note, call: nil, time: date(call.day)) }
    let need = memory.need
    switch policy {
    case "eager" where !call.notes.isEmpty:
        written += try await runJob(); ran += ran.isEmpty ? "after_call" : "+after_call"
    case "lobby" where !call.notes.isEmpty:
        if need == .now { written += try await runJob(); ran += ran.isEmpty ? "after_call" : "+after_call" }
        else if need == .overnight { overnight = true }
    default: break
    }
    let cover = memory.cover()
    log.append([call.day, number, call.notes.count, memory.notes.count, memory.summaries.count, memory.roots.count,
                cover.count, max(0, memory.roots.count - cover.count), memory.callText()?.count ?? 0].map(String.init).joined(separator: "\t")
               + "\t\(need)\t\(ran)\t\(written)")
    let lastOfDay = number == calls.count - 1 || calls[number + 1].day != call.day
    if lastOfDay, let next = checkpoints.first, call.day >= next {
        checkpoints.removeFirst()
        try await quizAt(call.day, final: checkpoints.isEmpty)
    }
}

// MARK: Outputs

var tree = ""
for summary in memory.summaries.sorted(by: { ($0.level, $0.index) < ($1.level, $1.index) }) {
    let span = Memory.span(level: summary.level, index: summary.index)
    tree += "L\(summary.level) #\(summary.index) notes \(span.lowerBound)-\(span.upperBound) (\(summary.text.utf8.count) bytes): \(summary.text)\n"
}
let cut = rawBytes.filter { $0 > Memory.noteBytes }.count
report += "## Summary lengths\n\nAs written: \(rawBytes.sorted()) bytes; \(cut) of \(rawBytes.count) over \(Memory.noteBytes) and cut.\n\n"
report += "## Cost\n\n\(empties) empty replies. \(requests["summary"]!) summaries, \(tokens["summary"]!) tokens; quiz \(tokens["quiz"]!) tokens.\n"
try log.joined(separator: "\n").write(to: out.appendingPathComponent("calls.tsv"), atomically: true, encoding: .utf8)
try tree.write(to: out.appendingPathComponent("summaries.txt"), atomically: true, encoding: .utf8)
try report.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
let encoder = JSONEncoder()
try encoder.encode(memory).write(to: out.appendingPathComponent("memory.json"))
print("\(memory.notes.count) notes, \(memory.summaries.count) summaries; \(requests["summary"]!) summary requests, \(tokens["summary"]!) tokens")
