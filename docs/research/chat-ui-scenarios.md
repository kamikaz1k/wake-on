# Call chat UI: scenarios to score libraries against

What the Wake On call chat has to handle, so candidate iOS libraries can be scored on
capability rather than stars. The scrolling and layout rules come from shadcn's
"What Makes a Great Streaming Chat Experience" (MessageScroller docs, June 2026); the rest
come from how GPT-Live calls actually behave.

Guiding rule (shadcn): **never move the reader against their intent.**

Scoring per scenario: **2** works out of the box, **1** works with our own code on top,
**0** fights the library. Each score is backed by a screenshot or a measurement from a
replayed call (see "How to test" at the end).

## A. Scrolling and reading position (shadcn)

- **A1 Move only when asked.** If you are reading, nothing pulls you elsewhere. Auto-scroll
  is not on by default.
- **A2 Follow only while following.** At the live edge, the stream stays in view; scroll away
  and the view stays where you left it.
- **A3 Every interaction is a signal.** Dragging, selecting text, opening a link, expanding a
  tool row, or VoiceOver focus all stop the view from moving.
- **A4 New turn near the top.** When you start speaking, your message settles near the top
  of the screen so the turn reads from its beginning.
- **A5 Reply grows into the screen.** Lobby's answer streams into the space below, without
  pushing everything away at once.
- **A6 Keep context.** A slice of the previous turn stays visible above the new one.
- **A7 Offscreen arrival.** New content can stream in out of view without changing what you
  are looking at.
- **A8 Show what's out of view.** A clear sign that Lobby is still talking or that new
  messages arrived below.
- **A9 Jump to latest.** One tap returns to the live edge and resumes following.
- **A10 Jump anywhere.** Jump to a message or turn in a long call (from search or an outline).
- **A11 Reopen at the last meaningful turn.** A saved chat log opens at your last message
  with Lobby's reply below, not at the very bottom. No visible jump on open.
- **A12 Stable through layout changes.** Markdown expanding, a tool row opening, an image or
  card loading: none of it shifts what you are reading.
- **A13 Interruptions keep position.** Barge-in, a failed call, a reconnect, or a retried
  tool does not move the view.
- **A14 Responsive in long calls.** Hundreds of turns with markdown and tool rows stay smooth.
- **A15 Accessible without noise.** VoiceOver can navigate the transcript, new rows are
  announced at a calm pace, and streaming text is not read out token by token.

## B. Voice transcript streaming (GPT-Live)

- **B1 Your words stream in** as they're transcribed (`input_transcript.delta`), including
  revisions of earlier words.
- **B2 Lobby's words stream in** while it speaks (`output_transcript.delta`), even when the
  text runs ahead of the audio.
- **B3 Barge-in.** When you interrupt, Lobby's reply is marked as cut off, not shown as
  complete.
- **B4 Out-of-order turns.** Your transcript often finishes after Lobby starts replying; it
  must slot in above the reply, without jumping the view (ties to A12).
- **B5 Wake-word burst.** After "Hey Lobby", the whole first request arrives at once from
  the kept audio.
- **B6 Live status with shimmer.** "Listening…", "Thinking…", "Searching the web…" as an
  animated status line that disappears when done (shadcn's shimmer).

## C. Tool calls

- **C1 Tool row lifecycle.** A row (shadcn's Marker) goes requested → running → done or
  failed, with the tool name (web_search, play_spotify, control_media).
- **C2 Details on tap.** Arguments and result are collapsed by default and expand on tap
  (collapsible content).
- **C3 Tools before text.** A turn can start with a tool and no words, or run several tools.
- **C4 Sources.** Web search shows its sources as links.

## D. Message building blocks (shadcn Message, Bubble, Marker, Attachment)

- **D1 Message row.** Alignment by speaker, optional header (name, time), footer, and
  grouping of consecutive messages.
- **D2 Bubble variants.** User and Lobby styles, links and buttons inside, and collapsible
  long content.
- **D3 Markers.** System notes and separators: call started (Action Button, Hey Lobby, in
  app), call ended (bye, button, timeout), date breaks between calls.
- **D4 Formatted text while streaming.** Lists, links, code and tables render as they arrive
  with no flicker (half-written markdown is closed while streaming).
- **D5 Custom views in messages.** Any SwiftUI view can sit in a row: the hook for charts
  and generated UI later.
- **D6 Attachments (later).** Images or files in a message, with loading state. Not needed
  for voice calls today.
- **D7 Scroll-fade.** Soft fades at the scroll edges hinting there is more content.

## E. Debug lens

- **E1 Raw events.** A switch that shows exactly what was sent to and received from OpenAI
  for each turn (events, tool arguments, results).
- **E2 Turn timing.** Per-turn numbers inline: response time, and for the first turn,
  connect time.

## F. Layout and input

- **F1 No typing box during calls**, with room to add one later.
- **F2 Fits the Simple tab** under the orb at compact height; dark mode; larger text sizes.
- **F3 Same view for saved chat logs** (replay from the chat log store).
- **F4 Mute and call state** visible without leaving the chat.

## G. Practical constraints

- **G1 Update rate.** 20 to 50 text updates a second with no dropped frames and no effect on
  call audio.
- **G2 Fit.** SwiftUI, iOS 17+, a permissive license (MIT or Apache), no vendor backend,
  Swift Package Manager, maintained.

## Candidates

- Plain SwiftUI (`ScrollView` + `LazyVStack` + scroll position APIs): the baseline any
  library must beat.
- exyte/Chat, with MarkdownView (Lakr233) for message text.
- ConversationKit (Peter Friese).
- LanguageModelChatUI (Lakr233, UIKit).

Stream's StreamChatAI is excluded: its license only covers Stream customers.

## How to test

1. Record a real call's event sequence from the phone logs: transcript deltas for both
   sides, a tool call, a barge-in, and a late user transcript.
2. Replay it, at real timing, into a small test screen per candidate in the simulator.
3. Score each scenario 0/1/2 with screenshots; measure G1 with frame timing during replay.

## First pass (Nov 2026, from simulator screenshots)

Built in the Chat Lab app (`native/ios/ChatLab`, scheme `ChatLab`). These notes come from
screenshots without touch; scores should come from trying each page on the phone.

- **Our SwiftUI (was "Plain"):** now implements shadcn's scroll rules itself (iOS 18 `scrollPosition`,
  scroll geometry and phase): new turns anchor 64 pt below the top with the previous turn peeking,
  follows only while at the live edge, a jump button says what's below, an outline with search
  jumps to any turn, saved calls open at the last message. Markdown is still inline-only.
- **exyte/Chat + MarkdownView:** upside-down `UITableView`; opens and follows at the bottom,
  built-in scroll-to-bottom button, keeps place on inserts (unverified by touch). No turn
  anchoring near the top. Input hides cleanly (F1). A custom message view replaces the whole
  row, so Lobby loses exyte's avatar/name/time. MarkdownView renders tables and code well, but its
  SwiftUI wrapper measures height after layout: in exyte's recycled cells that changed the list
  height near the top and caused a bounce loop on the phone. Fixed in the lab with our own
  wrapper that sizes during layout (`SizedMarkdown`); a swipe UI test (ChatLabUITests) confirmed it.
  On the phone, a new message stops a fling mid-scroll: exyte inserts with `reloadData` and then
  restores the offset with `setContentOffset`, which cancels deceleration (hurts A1, A7). Default user bubble
  truncates some messages (layout bug). Heavy dependencies (Giphy, Kingfisher, MediaPicker).
- **ConversationKit:** "push and pin" anchors a new user message at the top (A4/A5 partly), but
  then keeps it pinned while the reply streams off-screen; no follow mode or jump button; only
  a drag releases it. Saved logs open at the top. Composer can't be hidden (fails F1) and covers
  the last rows. MarkdownUI shows half-written tables as raw text until complete.
- **LanguageModelChatUI:** single "pinned to bottom" flag; every new turn pulls a reader back to
  the bottom. Best streaming markdown of the four (FlowDown's MarkdownView with its own
  batching), held 60 fps at 40 updates/s. Built for typed chat: user text can't stream,
  tool rows can't expand and have a running-state label bug, no custom views (no charts),
  input bar can't be turned off (pushed off-screen by our container).

None of the libraries anchors a new turn near the top with context and follows the live edge
only while you're there, which was the core of shadcn's rules.
