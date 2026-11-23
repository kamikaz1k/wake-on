// Simulates Lobby's memory filling up over months of calls, with the app's own `Memory` code
// (copied out of WakeOn/Memory.swift by run.sh) and real summaries from OpenAI. See README.md.
//
//   run.sh <out-dir> [lobby|eager|never]
//
// lobby: the app's policy (MemoryJob): nothing after a call that saved no note, an overnight run
//        once the start-of-call memory passes 24 lines, a run right after the call past 40.
// eager: summarize everything ready after every call that saved a note.
// never: no summaries.
//
// Environment: SUMMARY_MODEL, SUMMARY_EFFORT (default: the app's), QUIZ_MODEL (the call's
// backend model), GRADE_MODEL, COVER (run.sh: even or fading), LEGACY=1 (the first version: one try, the line cut at 280 bytes;
// run.sh also sets 8 notes per block for it), DATA (a folder with its own persona.txt and quiz.txt),
// TOOLS (recall, or recall,zoom), START (day 0, e.g. 2026-10-21), CHECKPOINTS (quiz days, e.g. 10,20,33; the last asks everything).
import Foundation

let args = CommandLine.arguments
let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DATA"] ?? args[1])
let out = URL(fileURLWithPath: args[2])
let policy = args.count > 3 ? args[3] : "lobby"
let env = ProcessInfo.processInfo.environment
let key = env["OPENAI_API_KEY"] ?? ""
let summaryModel = env["SUMMARY_MODEL"] ?? Memory.summaryModel
let summaryEffort = env["SUMMARY_EFFORT"] ?? Memory.summaryEffort
let quizModel = env["QUIZ_MODEL"] ?? "gpt-5.6-terra"
let gradeModel = env["GRADE_MODEL"] ?? "gpt-6.1-terra"
let legacy = env["LEGACY"] == "1"
/// Memory tools the quiz may use with recall: recall, or recall,zoom.
let toolNames = (env["TOOLS"] ?? "recall").split(separator: ",").map(String.init)
var zooms = 0
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Dollars per million tokens: input, cached input, output (developers.openai.com/api/docs/pricing, Nov 22 2026).
let prices: [String: (Double, Double, Double)] = [
    "gpt-5.4-mini": (0.75, 0.075, 4.50), "gpt-5.4": (2.50, 0.25, 15.00), "gpt-5.5": (5.00, 0.50, 30.00),
    "gpt-5.6-luna": (0.20, 0.02, 1.20), "gpt-5.6-terra": (2.00, 0.20, 12.00), "gpt-5.6-sol": (4.00, 0.40, 20.00),
    "gpt-6-luna": (0.10, 0.01, 0.50), "gpt-6.1-terra": (1.00, 0.05, 5.00), "gpt-6.2-sol": (2.00, 0.10, 10.00),
    "gpt-6.2-astra": (8.00, 0.40, 40.00),
]

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

let start = ISO8601DateFormatter().date(from: (env["START"] ?? "2026-08-01") + "T18:00:00Z")!
func date(_ day: Int) -> Date { start.addingTimeInterval(Double(day) * 86400) }

// MARK: OpenAI

struct Usage { var requests = 0, input = 0, cached = 0, output = 0, dollars = 0.0 }
var usage: [String: Usage] = [:]
var empties = 0

func respond(_ body: [String: Any], kind: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    var lastError = ""
    for _ in 0..<3 {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            lastError = String(data: data, encoding: .utf8) ?? ""
            try await Task.sleep(nanoseconds: 3_000_000_000)
            continue
        }
        let model = body["model"] as? String ?? ""
        let used = json["usage"] as? [String: Any] ?? [:]
        let input = used["input_tokens"] as? Int ?? 0, output = used["output_tokens"] as? Int ?? 0
        let cached = (used["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let price = prices[model] ?? (0, 0, 0)
        var entry = usage[kind] ?? Usage()
        entry.requests += 1; entry.input += input; entry.cached += cached; entry.output += output
        entry.dollars += (Double(input - cached) * price.0 + Double(cached) * price.1 + Double(output) * price.2) / 1e6
        usage[kind] = entry
        return json
    }
    throw NSError(domain: "openai", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError])
}

func replyText(_ json: [String: Any]) -> String {
    let parts = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
    let text = parts.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
    if text.isEmpty { empties += 1 }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: Summaries (as MemorySummarizer in the app)

var firstTries: [Int] = []
var retries = 0, failures = 0

let legacyPrompt = """
You compress a voice assistant's memory of its user. Merge the lines you're given, oldest first, into one line of at most 280 characters. Keep names, dates, places, preferences, plans and decisions that could matter later; drop the rest. When lines disagree, the later one wins. Reply with the line only.
"""

/// The app's request and retry; nil when it stayed too long.
func summarize(_ lines: [String]) async throws -> String? {
    if legacy {
        let body: [String: Any] = ["model": summaryModel, "instructions": legacyPrompt, "input": lines.joined(separator: "\n"),
                                   "store": false, "max_output_tokens": 400, "reasoning": ["effort": summaryEffort]]
        let line = replyText(try await respond(body, kind: "summary"))
        firstTries.append(line.utf8.count)
        let cut = Memory.oneLine(line)
        return cut.isEmpty ? nil : cut
    }
    var attempts: [String] = []
    for _ in 0..<Memory.summaryTries {
        let body = Memory.summaryRequest(lines, attempts: attempts, model: summaryModel, effort: summaryEffort)
        let line = replyText(try await respond(body, kind: "summary"))
        if attempts.isEmpty { firstTries.append(line.utf8.count) } else { retries += 1 }
        if !line.isEmpty, Memory.tooLong(line) == nil { return line }
        attempts.append(line)
    }
    failures += 1
    return nil
}

// MARK: Quiz

func schema(_ name: String, _ item: [String: Any]) -> [String: Any] {
    ["format": ["type": "json_schema", "name": name, "strict": true,
                "schema": ["type": "object", "additionalProperties": false, "required": ["items"],
                           "properties": ["items": ["type": "array", "items": item]]]]]
}

func items(_ reply: String) -> [String] {
    ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])?["items"] as? [String] ?? []
}

/// All questions at once, from the start-of-call memory only.
func askFromMemory(_ questions: [Question], memory text: String) async throws -> [String] {
    let reply = replyText(try await respond([
        "model": quizModel, "store": false, "reasoning": ["effort": "low"],
        "instructions": "You are Lobby, a voice assistant. Answer each question about the user from the memory below only, in a few words. If the memory doesn't say, answer \"don't know\".\n\n" + text,
        "input": questions.enumerated().map { "\($0.offset + 1). \($0.element.q)" }.joined(separator: "\n"),
        "text": schema("answers", ["type": "string"]),
    ], kind: "quiz"))
    let answers = items(reply)
    return questions.indices.map { $0 < answers.count ? answers[$0] : "" }
}

var recalls = 0

/// One question, as in a call: the memory plus the app's recall tool.
func askWithRecall(_ question: String, memory text: String) async throws -> String {
    var input: [[String: Any]] = [["role": "user", "content": question]]
    let body: [String: Any] = [
        "model": quizModel, "store": false, "reasoning": ["effort": "low"], "tools": Memory.tools.filter { toolNames.contains($0["name"] as? String ?? "") },
        "instructions": "You are Lobby, a voice assistant. Answer the user's question about themselves in a few words. " + Memory.delegationInstructions + " If you still can't find it, say you don't know.\n\n" + text,
    ]
    for _ in 0..<6 {
        var request = body
        request["input"] = input
        let output = try await respond(request, kind: "quiz")["output"] as? [[String: Any]] ?? []
        let calls = output.filter { $0["type"] as? String == "function_call" }
        if calls.isEmpty {
            return output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
        }
        for call in calls {
            input.append(call)
            let arguments = (try? JSONSerialization.jsonObject(with: Data((call["arguments"] as? String ?? "{}").utf8))) as? [String: Any]
            let output: String
            if call["name"] as? String == Memory.zoomTool {
                zooms += 1
                output = memory.zoom(arguments?["id"] as? String ?? "")
            } else {
                recalls += 1
                output = Memory.recallText(memory.recall(arguments?["query"] as? String ?? ""))
            }
            input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "", "output": output])
        }
    }
    return ""
}

func grade(_ questions: [Question], _ answers: [String]) async throws -> [String] {
    let item: [String: Any] = ["type": "string", "enum": ["right", "partly", "stale", "wrong", "missing"]]
    let input = questions.indices.map { "\($0 + 1). Q: \(questions[$0].q)\nExpected: \(questions[$0].expected)\nGot: \(answers[$0])" }
    return items(replyText(try await respond([
        "model": gradeModel, "store": false, "reasoning": ["effort": "low"],
        "instructions": "Grade each answer against the expected one. right: gets the main fact the question asks for (extra detail in the expected answer, in parentheses or after a semicolon, is optional). partly: half of a two-part answer. stale: gives an answer that was true earlier but changed (the expected answer says what it changed from). wrong: otherwise incorrect. missing: says it doesn't know.",
        "input": input.joined(separator: "\n\n"), "text": schema("grades", item),
    ], kind: "quiz")))
}

// MARK: The run

var memory = Memory()
var log: [String] = ["day\tcall\tsaved\tnotes\tsummaries\troots\tcover\tleft_out\tchars\tneed\tran\twritten"]
var overnight = false
var checkpoints = env["CHECKPOINTS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [30, 60, calls.last!.day]
var report = "# Memory simulation: \(policy), \(legacy ? "first version" : "OptMem merges"), \(Memory.coverRule) cover, blocks up to \(Memory.rawMax) notes from the notes, summaries by \(summaryModel) (\(summaryEffort))\n\n"
var scores: [[String: Any]] = []
/// Every question's grades, and each checkpoint's lines (days since the oldest note, notes covered).
var grades: [[String: Any]] = []
var profiles: [[String: Any]] = []

func runJob() async throws -> Int {
    var written = 0
    while written < 128, let next = memory.ready.first {
        let input = memory.summaryInput(level: next.level, index: next.index)
        guard let line = try await summarize(input), memory.setSummary(level: next.level, index: next.index, text: line) else { break }
        written += 1
    }
    return written
}

func quizAt(_ day: Int, final: Bool) async throws {
    // Facts that change later have their final answer in quiz.txt, so they're asked only at the end.
    let known = quiz.filter { $0.day <= day && (final || $0.kind != "update") }
    let text = memory.callText() ?? ""
    try text.write(to: out.appendingPathComponent("call-start-day\(day).txt"), atomically: true, encoding: .utf8)
    let plain = try await askFromMemory(known, memory: text)
    let plainGrades = try await grade(known, plain)
    recalls = 0; zooms = 0
    var searched: [String] = []
    for question in known { searched.append(try await askWithRecall(question.q, memory: text)) }
    let searchedGrades = try await grade(known, searched)
    let score = { (grades: [String]) in grades.filter { $0 == "right" }.count }
    report += "## Day \(day): \(score(plainGrades)) of \(known.count) right from memory alone, \(score(searchedGrades)) with \(toolNames.joined(separator: " and ")) (\(recalls) searches, \(zooms) zooms)\n\n"
    report += "\(memory.notes.count) notes, \(memory.summaries.count) summaries, \(memory.cover().count) lines at call start (\(text.count) characters).\n\n"
    report += "| kind | question | memory alone | with recall |\n|---|---|---|---|\n"
    for index in known.indices {
        let a = index < plainGrades.count ? plainGrades[index] : "?", b = index < searchedGrades.count ? searchedGrades[index] : "?"
        report += "| \(known[index].kind) | \(known[index].q) | \(plain[index]) (\(a)) | \(searched[index].replacingOccurrences(of: "\n", with: " ")) (\(b)) |\n"
    }
    report += "\n"
    for index in known.indices {
        grades.append(["day": day, "q": known[index].q, "kind": known[index].kind, "known": known[index].day,
                       "memory": index < plainGrades.count ? plainGrades[index] : "?",
                       "recall": index < searchedGrades.count ? searchedGrades[index] : "?"])
    }
    profiles.append(["day": day, "lines": memory.cover().map { unit -> [Int] in
        switch unit {
        case let .note(note): [Int((date(day).timeIntervalSince(note.time) / 86400).rounded()), 1]
        case let .summary(summary): [Int((date(day).timeIntervalSince(summary.from) / 86400).rounded()),
                                     Memory.span(level: summary.level, index: summary.index).count]
        }
    }])
    scores.append(["day": day, "asked": known.count, "memory": score(plainGrades), "recall": score(searchedGrades), "searches": recalls, "zooms": zooms])
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
let s = usage["summary"] ?? Usage()
let over = firstTries.filter { $0 > Memory.noteBytes }.count
report += "## Summaries\n\n\(s.requests) requests for \(memory.summaries.count) summaries: \(over) of \(firstTries.count) first tries over \(Memory.noteBytes) bytes, \(retries) retries, \(failures) still too long after \(Memory.summaryTries) tries, \(empties) empty replies.\n\n"
report += "First tries, bytes: \(firstTries.sorted())\n\n"
report += String(format: "Tokens: %d in (%d cached), %d out. Cost: $%.4f for %d notes, $%.4f per 100 notes.\n",
                 s.input, s.cached, s.output, s.dollars, memory.notes.count, s.dollars / Double(max(1, memory.notes.count)) * 100)
try log.joined(separator: "\n").write(to: out.appendingPathComponent("calls.tsv"), atomically: true, encoding: .utf8)
try tree.write(to: out.appendingPathComponent("summaries.txt"), atomically: true, encoding: .utf8)
try report.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
try JSONEncoder().encode(memory).write(to: out.appendingPathComponent("memory.json"))
let result: [String: Any] = [
    "model": summaryModel, "effort": summaryEffort, "legacy": legacy, "policy": policy, "cover": "\(Memory.coverRule)", "tools": toolNames, "rawMax": Memory.rawMax,
    "notes": memory.notes.count, "summaries": memory.summaries.count, "requests": s.requests,
    "overFirstTry": over, "retries": retries, "failures": failures, "empties": empties,
    "inputTokens": s.input, "outputTokens": s.output, "dollars": s.dollars, "scores": scores, "grades": grades, "profiles": profiles,
]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("result.json"))
print(String(format: "%@: %d summaries, %d requests, %d retries, %d failures, $%.4f", summaryModel, memory.summaries.count, s.requests, retries, failures, s.dollars))
