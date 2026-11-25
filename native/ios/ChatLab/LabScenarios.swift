import Foundation

/// One scenario from docs/research/chat-ui-scenarios.md, with a script that exercises it.
struct LabScenario: Identifiable {
    let id: String          // "A1"
    let title: String
    let lookFor: String     // what to check on each library page
    var compact = false     // F2: render at the Simple tab's height under the orb
    var showsFrameRate = false
    let script: () -> [ChatStep]

    var group: String { String(id.prefix(1)) }
}

enum LabGroup: String, CaseIterable, Identifiable {
    case A = "Scrolling and reading position"
    case B = "Voice transcript streaming"
    case C = "Tool calls"
    case D = "Message building blocks"
    case E = "Debug lens"
    case F = "Layout and input"
    case G = "Practical constraints"
    var id: String { String(describing: self) }
}

// MARK: - Sample content

enum LabText {
    static let questions = [
        "What's the weather like in Paris right now?",
        "Play Come Sail Away by Styx.",
        "Pause the music.",
        "How long would it take to drive from Toronto to Montreal?",
        "Remind me what we talked about yesterday.",
        "What's a good recipe for dinner tonight?",
        "Who won the game last night?",
        "Turn it back on.",
    ]
    static let answers = [
        "It's clear in Paris, about 11 degrees with a light wind from the west.",
        "Playing Come Sail Away by Styx on Spotify.",
        "Paused.",
        "About five and a half hours, mostly along the 401. Leave before 3 to beat traffic out of the city.",
        "We talked about your trip to Lisbon and which neighbourhood to stay in. You leaned toward Alfama.",
        "How about a one-pan lemon chicken with potatoes? It takes about 40 minutes and very little cleanup.",
        "The Raptors won 112 to 104. Barnes had 31 points.",
        "Resumed.",
    ]
    static let long = """
    Here's a plan for Saturday in Lisbon.

    **Morning**
    - Start in Alfama with a coffee at a miradouro.
    - Walk down to the Sé cathedral, then the riverfront.

    **Afternoon**
    1. Tram 28 to Estrela.
    2. Lunch in Campo de Ourique; the market has good small plates.
    3. Head to LX Factory for books and a late espresso.

    **Evening**
    Dinner in Bairro Alto, then a fado show. Book ahead: the small houses fill up by 8.

    | Stop | Time | Note |
    |------|------|------|
    | Alfama | 9:00 | Wear good shoes |
    | Estrela | 13:00 | Tram can be busy |
    | Bairro Alto | 20:00 | Book fado |

    If it rains, swap the afternoon for the Gulbenkian museum. More at [visitlisboa.com](https://www.visitlisboa.com).
    """
    static let wideTable = """
    Here are the five hotels side by side.

    | Hotel | Area | Price/night | Rating | Walk to tram | Breakfast | Cancellation |
    |-------|------|-------------|--------|--------------|-----------|--------------|
    | Memmo Alfama | Alfama | €240 | 4.7 | 3 min | Included | Free until 48 h |
    | Lumiares | Bairro Alto | €210 | 4.6 | 5 min | €18 | Free until 24 h |
    | Santiago de Alfama | Alfama | €265 | 4.8 | 4 min | Included | Non-refundable |
    | Casa do Barão | Chiado | €150 | 4.4 | 6 min | €12 | Free until 72 h |
    | The Lumiares Annex | Príncipe Real | €185 | 4.5 | 8 min | None | Free until 24 h |

    Casa do Barão is the best value; Santiago de Alfama has the best views.
    """
    static let code = """
    Sure. To pause from a shortcut, call the media command like this:

    ```swift
    MRMediaRemoteSendCommand(MRCommand.pause, nil)
    ```

    It works with the phone locked. Then say **"resume"** to start it again.
    """
}

extension ChatScript {
    /// Finished turns, shown at once: earlier parts of the call.
    mutating func history(_ turns: Int, startingAt offset: Int = 0) {
        for index in 0..<turns {
            let i = (index + offset) % LabText.questions.count
            said(.user, LabText.questions[i])
            said(.lobby, LabText.answers[i], timing: "Reply in \(String(format: "%.1f", 0.9 + Double(i % 4) * 0.3)) s")
        }
    }
}

// MARK: - Scenarios

enum LabScenarios {
    static func script(_ build: @escaping (inout ChatScript) -> Void) -> () -> [ChatStep] {
        { var script = ChatScript(); build(&script); return script.steps }
    }

    static let all: [LabScenario] = scrolling + transcript + tools + blocks + debug + layout + constraints

    // A. Scrolling (shadcn)

    static let scrolling: [LabScenario] = [
        LabScenario(id: "A1", title: "Move only when asked",
                    lookFor: "While the long reply streams, scroll up a little. The view should stay where you put it, not snap back down.",
                    script: script { s in
                        s.history(5); s.wait(1.5)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "A2", title: "Follow only while following",
                    lookFor: "Leave it alone: the reply should stay in view as it grows. Then scroll away: it should stop following until you return to the bottom.",
                    script: script { s in
                        s.history(4); s.wait(1)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long + "\n\n" + LabText.long, wordsPerSecond: 7)
                    }),
        LabScenario(id: "A3", title: "Every interaction is a signal",
                    lookFor: "While it streams, long-press to select text, tap the link, or tap the tool row. Each should stop the view from moving.",
                    script: script { s in
                        s.history(3); s.wait(1)
                        s.stream(.user, "Find a fado show tonight and plan the evening.", wordsPerSecond: 2.5)
                        s.tool("web_search", arguments: #"{"query":"fado show Lisbon tonight"}"#, result: "3 results",
                               sources: [.init(title: "Clube de Fado", url: "https://clube-de-fado.com")])
                        s.stream(.lobby, LabText.long, wordsPerSecond: 4)
                    }),
        LabScenario(id: "A4", title: "New turn near the top",
                    lookFor: "When your new message appears, it should settle near the top of the screen, not at the bottom edge.",
                    script: script { s in
                        s.history(6); s.wait(2)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "A5", title: "Reply grows into the screen",
                    lookFor: "\(Agent.name)'s answer should fill the space below your message, without the whole thread jumping up at once.",
                    script: script { s in
                        s.history(6); s.wait(2)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "A6", title: "Keep context",
                    lookFor: "When the new turn settles near the top, a slice of the previous reply should stay visible above it.",
                    script: script { s in
                        s.history(6); s.wait(2)
                        s.stream(.user, "And on Sunday?", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "A7", title: "Offscreen arrival",
                    lookFor: "Scroll up to read an early message. New turns keep streaming below without changing what you see.",
                    script: script { s in
                        s.history(8); s.wait(2)
                        for turn in 0..<3 {
                            s.stream(.user, LabText.questions[turn + 3], wordsPerSecond: 2.5)
                            s.wait(0.6); s.stream(.lobby, LabText.answers[turn + 3], wordsPerSecond: 5); s.wait(1)
                        }
                    }),
        LabScenario(id: "A8", title: "Show what's out of view",
                    lookFor: "Scroll up while it streams. Is there a sign that \(Agent.name) is still talking or that new messages arrived below?",
                    script: script { s in
                        s.history(8); s.wait(2)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 4)
                    }),
        LabScenario(id: "A9", title: "Jump to latest",
                    lookFor: "Scroll up, then look for a button that takes you back to the newest line and resumes following.",
                    script: script { s in
                        s.history(10); s.wait(2)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long + "\n\n" + LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "A10", title: "Jump anywhere",
                    lookFor: "A 40-turn call. Is there a way to search, see an outline, or jump to a specific turn?",
                    script: script { s in s.marker("Call started · \(Agent.wakePhrase)"); s.history(40) }),
        LabScenario(id: "A11", title: "Reopen at the last meaningful turn",
                    lookFor: "A saved call opens. It should land on your last message with the reply below, not the very bottom, and without a visible jump.",
                    script: script { s in
                        s.marker("Yesterday · Action Button"); s.history(8)
                        s.said(.user, "Plan my Saturday in Lisbon.")
                        s.said(.lobby, LabText.long + "\n\n" + LabText.long, timing: "Reply in 1.4 s")
                        s.marker("Call ended · bye")
                    }),
        LabScenario(id: "A12", title: "Stable through layout changes",
                    lookFor: "Scroll to read the middle. Content above changes size (a late transcript, an expanding table, a card loading). Your place should not move.",
                    script: script { s in
                        s.history(5)
                        let reply = s.stream(.lobby, "Here's the table you asked for.", wordsPerSecond: 8)
                        s.history(3, startingAt: 5); s.wait(2.5)
                        s.stream(.user, "Can you compare the hotels?", wordsPerSecond: 3, insertBefore: reply)
                        s.wait(1.5); s.run { $0.update(reply) { $0.kind = .message(.lobby, text: LabText.long, state: .done) } }
                        s.wait(1.5); s.card(.chart(title: "Hotel prices this week", points: [180, 210, 195, 240, 260, 230, 205]))
                    }),
        LabScenario(id: "A13", title: "Interruptions keep position",
                    lookFor: "Scroll up a bit. A barge-in, a dropped connection, a reconnect and a retried tool happen below; your view should not move.",
                    script: script { s in
                        s.history(6); s.wait(1.5)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.stream(.lobby, LabText.long, wordsPerSecond: 5, cutAfterWords: 18)
                        s.stream(.user, "Actually, just the evening.", wordsPerSecond: 2.5)
                        s.marker("Connection lost", .error); s.wait(1.5); s.marker("Reconnected")
                        s.tool("web_search", arguments: #"{"query":"fado Lisbon tonight"}"#, result: nil, runFor: 1, fails: true)
                        s.tool("web_search", arguments: #"{"query":"fado Lisbon tonight"}"#, result: "4 results")
                        s.stream(.lobby, "Dinner in Bairro Alto, then fado at Clube de Fado at 9:30.", wordsPerSecond: 5)
                    }),
        LabScenario(id: "A14", title: "Responsive in long calls",
                    lookFor: "300 turns, then a fast streaming reply. Scrolling should stay smooth; watch the frame counter.",
                    showsFrameRate: true,
                    script: script { s in
                        s.history(300); s.wait(1.5)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 3)
                        s.stream(.lobby, LabText.long + "\n\n" + LabText.code, wordsPerSecond: 20)
                    }),
        LabScenario(id: "A15", title: "Accessible without noise",
                    lookFor: "Turn on VoiceOver (triple-click the side button if set up). New rows should be announced calmly, not word by word, and the transcript should be navigable.",
                    script: script { s in
                        s.history(3); s.wait(1.5)
                        s.stream(.user, "What's the weather in Paris?", wordsPerSecond: 2.5)
                        s.status("Searching the web…")
                        s.tool("web_search", arguments: #"{"query":"Paris weather now"}"#, result: "11°C, clear")
                        s.status(nil)
                        s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4)
                    }),
    ]

    // B. Voice transcript (GPT-Live)

    static let transcript: [LabScenario] = [
        LabScenario(id: "B1", title: "Your words stream in, with revisions",
                    lookFor: "Your message fills in word by word, then the transcription corrects itself (\"come sail away\" becomes \"Come Sail Away by Styx\").",
                    script: script { s in
                        s.history(2)
                        let id = s.stream(.user, "play come sail away with me ", wordsPerSecond: 2.5)
                        s.wait(0.6); s.revise(id, .user, to: "Play Come Sail Away by Styx.")
                        s.wait(0.8); s.stream(.lobby, "Playing Come Sail Away by Styx on Spotify.", wordsPerSecond: 4)
                    }),
        LabScenario(id: "B2", title: "\(Agent.name)'s words stream in",
                    lookFor: "\(Agent.name)'s text arrives in bursts, ahead of where its voice would be. Does it stream smoothly?",
                    script: script { s in
                        s.history(2)
                        s.stream(.user, "How long to drive to Montreal?", wordsPerSecond: 2.5)
                        s.wait(0.9); s.stream(.lobby, LabText.answers[3] + " " + LabText.answers[5], wordsPerSecond: 9)
                    }),
        LabScenario(id: "B3", title: "Barge-in",
                    lookFor: "You interrupt \(Agent.name) mid-sentence. The cut-off reply should look cut off, not complete.",
                    script: script { s in
                        s.history(2)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.wait(0.8); s.stream(.lobby, LabText.long, wordsPerSecond: 4, cutAfterWords: 22)
                        s.stream(.user, "Wait, just the evening please.", wordsPerSecond: 2.5)
                        s.wait(0.6); s.stream(.lobby, "Dinner in Bairro Alto, then a fado show.", wordsPerSecond: 4)
                    }),
        LabScenario(id: "B4", title: "Out-of-order turns",
                    lookFor: "\(Agent.name) starts replying before your transcript is finished. Your message should slot in above the reply.",
                    script: script { s in
                        s.history(3)
                        let reply = s.stream(.lobby, "Sure, here's how long it takes. ", wordsPerSecond: 5)
                        s.stream(.user, "How long to drive to Montreal?", wordsPerSecond: 4, insertBefore: reply)
                        s.run { $0.update(reply) { $0.kind = .message(.lobby, text: "Sure, here's how long it takes. " + LabText.answers[3], state: .done) } }
                    }),
        LabScenario(id: "B5", title: "Wake-word burst",
                    lookFor: "After \"\(Agent.wakePhrase)\", your whole request appears at once from the kept audio.",
                    script: script { s in
                        s.history(2); s.wait(1)
                        s.marker("\(Agent.wakePhrase)")
                        s.wait(1.2); s.said(.user, "What's the weather like in Paris, France right now?")
                        s.wait(0.9); s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4)
                    }),
        LabScenario(id: "B6", title: "Live status",
                    lookFor: "An animated status line (Listening, Thinking, Searching the web) that disappears when \(Agent.name) speaks.",
                    script: script { s in
                        s.history(2)
                        s.status("Listening…")
                        s.stream(.user, "Who won the game last night?", wordsPerSecond: 2.5)
                        s.status("Thinking…"); s.wait(1.2)
                        s.status("Searching the web…")
                        s.tool("web_search", arguments: #"{"query":"Raptors score last night"}"#, result: "Raptors 112, Knicks 104")
                        s.status(nil)
                        s.stream(.lobby, LabText.answers[6], wordsPerSecond: 4)
                    }),
    ]

    // C. Tools

    static let tools: [LabScenario] = [
        LabScenario(id: "C1", title: "Tool row lifecycle",
                    lookFor: "Each tool row goes requested → running → done (or failed), with its name.",
                    script: script { s in
                        s.history(1)
                        s.stream(.user, "Play Come Sail Away, then pause it.", wordsPerSecond: 2.5)
                        s.tool("play_spotify", arguments: #"{"query":"Come Sail Away Styx"}"#, result: "Opened Spotify")
                        s.tool("control_media", arguments: #"{"command":"pause"}"#, result: "Not playing yet", fails: true)
                        s.stream(.lobby, "Playing it now. I couldn't pause yet; ask again in a moment.", wordsPerSecond: 4)
                    }),
        LabScenario(id: "C2", title: "Details on tap",
                    lookFor: "Tap the tool row: its arguments and result should expand, and collapse again.",
                    script: script { s in
                        s.history(1)
                        s.stream(.user, "What's the weather in Paris?", wordsPerSecond: 2.5)
                        s.tool("web_search", arguments: #"{"query":"Paris weather now","units":"metric"}"#,
                               result: "Paris: 11°C, clear, wind W 12 km/h. Tonight 6°C.")
                        s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4)
                    }),
        LabScenario(id: "C3", title: "Tools before text",
                    lookFor: "The turn starts with tools and no words, and runs two tools before \(Agent.name) speaks.",
                    script: script { s in
                        s.history(1)
                        s.stream(.user, "Pause the music and tell me the score.", wordsPerSecond: 2.5)
                        s.tool("control_media", arguments: #"{"command":"pause"}"#, result: "Paused", runFor: 0.6)
                        s.tool("web_search", arguments: #"{"query":"Raptors score"}"#, result: "Raptors 112, Knicks 104")
                        s.stream(.lobby, "Paused. " + LabText.answers[6], wordsPerSecond: 4)
                    }),
        LabScenario(id: "C4", title: "Sources",
                    lookFor: "Web search shows its sources as tappable links.",
                    script: script { s in
                        s.history(1)
                        s.stream(.user, "Find a fado show tonight.", wordsPerSecond: 2.5)
                        s.tool("web_search", arguments: #"{"query":"fado show Lisbon tonight"}"#, result: "3 results", sources: [
                            .init(title: "Clube de Fado", url: "https://clube-de-fado.com"),
                            .init(title: "Tasca do Chico", url: "https://www.tripadvisor.com"),
                            .init(title: "Visit Lisboa: fado", url: "https://www.visitlisboa.com"),
                        ])
                        s.stream(.lobby, "Clube de Fado has a 9:30 show; Tasca do Chico is walk-in.", wordsPerSecond: 4)
                    }),
    ]

    // D. Building blocks

    static let blocks: [LabScenario] = [
        LabScenario(id: "D1", title: "Message rows",
                    lookFor: "Speakers line up on opposite sides, with a name or time header, and consecutive \(Agent.name) messages group together.",
                    script: script { s in
                        s.said(.user, "Pause the music.")
                        s.said(.lobby, "Paused.")
                        s.said(.lobby, "Want me to set a timer to resume?")
                        s.said(.lobby, "Say \"resume\" any time.")
                        s.said(.user, "No thanks.")
                        s.said(.user, "Actually, turn it back on.")
                        s.said(.lobby, "Resumed.")
                    }),
        LabScenario(id: "D2", title: "Bubble variants",
                    lookFor: "Distinct styles for you and \(Agent.name), a link and buttons inside a message, and a long message that can collapse.",
                    script: script { s in
                        s.said(.user, "Find me a fado show.")
                        s.said(.lobby, "Clube de Fado has a show at 9:30. Details at [clube-de-fado.com](https://clube-de-fado.com).")
                        s.card(.buttons(["Book 2 seats", "Directions", "Not tonight"]))
                        s.said(.lobby, LabText.long + "\n\n" + LabText.long)
                    }),
        LabScenario(id: "D3", title: "Markers",
                    lookFor: "System notes and separators: how the call started, a date break, and how it ended.",
                    script: script { s in
                        s.marker("Yesterday", .separator)
                        s.marker("Call started · Action Button")
                        s.history(2)
                        s.marker("Call ended · you said bye")
                        s.marker("Today", .separator)
                        s.marker("Call started · \(Agent.wakePhrase)")
                        s.history(1, startingAt: 2)
                        s.marker("Call ended · 10 s of silence")
                    }),
        LabScenario(id: "D4", title: "Formatted text while streaming",
                    lookFor: "Lists, bold, a table and a code block render as they stream, without flicker or raw ** and | symbols.",
                    script: script { s in
                        s.stream(.user, "Plan my Saturday and show me the pause code.", wordsPerSecond: 3)
                        s.wait(0.6); s.stream(.lobby, LabText.long + "\n\n" + LabText.code, wordsPerSecond: 25, chunkCharacters: 4)
                    }),
        LabScenario(id: "D5", title: "Custom views in messages",
                    lookFor: "A chart card sits in the transcript like a message: the hook for generated UI later.",
                    script: script { s in
                        s.history(1)
                        s.stream(.user, "How have hotel prices moved this week?", wordsPerSecond: 2.5)
                        s.wait(0.6); s.stream(.lobby, "Here's the trend for Alfama.", wordsPerSecond: 4)
                        s.card(.chart(title: "Hotel prices this week (€)", points: [180, 210, 195, 240, 260, 230, 205]))
                        s.stream(.lobby, "Thursday is the cheapest night to book.", wordsPerSecond: 4)
                    }),
        LabScenario(id: "D6", title: "Attachments",
                    lookFor: "An image in a message, with a caption. (Not needed for voice today.)",
                    script: script { s in
                        s.said(.user, "Show me the route.")
                        s.card(.image(systemName: "map", caption: "Toronto → Montreal, 5 h 30"))
                        s.said(.lobby, "That's the fastest route right now.")
                    }),
        LabScenario(id: "D8", title: "Wide table",
                    lookFor: "A seven-column table streams in. It should stay inside the bubble, scroll sideways, and offer a way to see it in full.",
                    script: script { s in
                        s.stream(.user, "Compare the hotels for me.", wordsPerSecond: 2.5)
                        s.wait(0.6); s.stream(.lobby, LabText.wideTable, wordsPerSecond: 20, chunkCharacters: 6)
                    }),
        LabScenario(id: "D7", title: "Scroll-fade",
                    lookFor: "Soft fades at the top and bottom edges hint that there is more to scroll.",
                    script: script { s in s.history(12) }),
    ]

    // E. Debug lens

    static let debug: [LabScenario] = [
        LabScenario(id: "E1", title: "Raw events",
                    lookFor: "What was sent to and received from OpenAI appears inline, collapsed, and opens to the full event.",
                    script: script { s in
                        s.event(.sent, "session.update", #"{"voice":"marin","tools":["web_search","play_spotify"]}"#)
                        s.event(.received, "session.started", #"{"id":"sess_9f2"}"#)
                        let user = s.stream(.user, "What's the weather in Paris?", wordsPerSecond: 2.5)
                        _ = user
                        s.event(.received, "session.input_transcript.done", #"{"text":"What's the weather in Paris?"}"#)
                        s.event(.received, "response.function_call", #"{"name":"web_search","arguments":{"query":"Paris weather"}}"#)
                        s.event(.sent, "response.item.create", #"{"type":"function_call_output","output":"11°C clear"}"#)
                        s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4)
                        s.event(.received, "response.done", #"{"usage":{"input_tokens":812,"output_tokens":41}}"#)
                    }),
        LabScenario(id: "E2", title: "Turn timing",
                    lookFor: "Under each \(Agent.name) reply, how long it took to answer (and connect time on the first turn).",
                    script: script { s in
                        s.marker("Connected in 0.88 s · \(Agent.wakePhrase)")
                        s.stream(.user, "What's the weather in Paris?", wordsPerSecond: 2.5)
                        s.wait(1.3); s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4, timing: "Reply in 1.3 s")
                        s.stream(.user, "Play Come Sail Away.", wordsPerSecond: 2.5)
                        s.wait(0.9); s.stream(.lobby, LabText.answers[1], wordsPerSecond: 4, timing: "Reply in 0.9 s")
                    }),
    ]

    // F. Layout and input

    static let layout: [LabScenario] = [
        LabScenario(id: "F1", title: "No typing box during calls",
                    lookFor: "There should be no text field or send button; voice is the input.",
                    script: script { s in
                        s.history(2)
                        s.stream(.user, "What's the weather in Paris?", wordsPerSecond: 2.5)
                        s.stream(.lobby, LabText.answers[0], wordsPerSecond: 4)
                    }),
        LabScenario(id: "F2", title: "Fits the Simple tab",
                    lookFor: "The chat shown at the height left under the orb on the Simple tab. Is it still readable? Try dark mode and larger text too.",
                    compact: true,
                    script: script { s in
                        s.history(3)
                        s.stream(.user, "Plan my Saturday in Lisbon.", wordsPerSecond: 2.5)
                        s.stream(.lobby, LabText.long, wordsPerSecond: 5)
                    }),
        LabScenario(id: "F3", title: "Same view for saved logs",
                    lookFor: "A finished call shown all at once, as it would be from the chat log list.",
                    script: script { s in
                        s.marker("Nov 7 · \(Agent.wakePhrase)")
                        s.history(5)
                        s.marker("Call ended · bye")
                    }),
        LabScenario(id: "F4", title: "Mute and call state",
                    lookFor: "The call's state (connecting, live, ended) and mute are visible without leaving the chat.",
                    script: script { s in
                        s.run { $0.call.phase = "Connecting" }; s.wait(1.2)
                        s.run { $0.call.phase = "Live" }
                        s.stream(.user, "Pause the music.", wordsPerSecond: 2.5)
                        s.stream(.lobby, "Paused.", wordsPerSecond: 4)
                        s.run { $0.call.muted = true }; s.wait(2.5)
                        s.run { $0.call.muted = false }
                        s.stream(.user, "Bye.", wordsPerSecond: 2.5)
                        s.stream(.lobby, "Bye!", wordsPerSecond: 4)
                        s.run { $0.call.phase = "Ended" }; s.marker("Call ended · bye")
                    }),
    ]

    // G. Constraints

    static let constraints: [LabScenario] = [
        LabScenario(id: "G1", title: "Update rate",
                    lookFor: "40 updates a second for 15 s. Watch the frame counter and whether scrolling stays smooth.",
                    showsFrameRate: true,
                    script: script { s in
                        s.history(10)
                        s.stream(.user, "Read me the whole plan, twice.", wordsPerSecond: 3)
                        s.stream(.lobby, String(repeating: LabText.long + "\n\n", count: 4), wordsPerSecond: 40)
                    }),
        LabScenario(id: "G2", title: "Fit",
                    lookFor: "Read the library facts at the top of each page: SwiftUI or UIKit, minimum iOS, license, dependencies.",
                    script: script { s in s.history(2) }),
    ]
}
