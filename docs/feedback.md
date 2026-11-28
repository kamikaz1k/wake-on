# Feedback triage

Feedback people send through Pixie lives in the server's KV for a year
(`cd server && node scripts/feedback.mjs [days]`); TestFlight screenshot and crash feedback is in
App Store Connect. The inbox has no status of its own, so decisions are kept here. This repo is
public: no names, and issues are paraphrased.

**Reviewed through:** 2026-11-26 17:21 UTC (reviewed 2026-11-28). Newer entries are unreviewed.

| Sent | Issue | Status |
|---|---|---|
| 2026-11-26 | Poor connection, Pixie repeating itself, slow replies (iPhone 14 Pro) | Closed: calls ride out network drops (1f494bd, a782737) |
| 2026-11-26 | Calls "cut short as tokens run out" | Closed: the chat-length warning was removed |
| 2026-11-26 | High token use while shopping and showing pictures | Closed |
| 2026-11-26 | "Hey Pixie" unreliable with background listening on (iPhone 14 Pro) | Closed for now, not investigated |
| 2026-11-26 | Memory didn't keep a short list the user asked for | Open, not started ([to do](todo.md)) |
| 2026-11-26 | Phone calls | Closed: contacts search and calling (49c4c7a); calling a business found on the web isn't supported |
| 2026-11-26 | A cue while Pixie works on a long request, sound or visual (for driving) | Closed: thinking sound after 3 s of lookups (05ae842); no visual/sound choice |
| 2026-11-26 | Developer should see the chat the feedback is about | Undecided: chats stay on the phone; feedback carries Pixie's note only. Attaching the call's log to feedback would cover it |
| 2026-11-26 | Pixie said it couldn't send feedback | Closed: send_feedback (973fe98) |
