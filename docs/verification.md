# Verification log

What has been checked, how, where, and at which commit. One row per check; newest first.
A row stays true only while its files are unchanged since its SHA:
`python3 .claude/skills/verification-log/stale.py` lists rows whose files changed since.
When a check is redone, add a new row rather than editing the old one.

- **How**: unit test, UI test, simulator (screenshot or run), phone (by Claude or by you), Instruments trace.
- **Where**: phone = iPhone on iOS 26.6.2; sim = iPhone 17 Pro simulator, iOS 26.5.
- **Files**: paths from the repo root, comma-separated; a folder covers everything in it.

## Checks

| Date | SHA | Check | How | Where | Result | Files |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-12 | 3652571 | Real call with the live screen: Action Button, two web searches, Spotify; captured and shown right in the chat log | phone, by you (1 call); capture pulled and its chat log opened in the simulator | phone, sim | Capture complete (searches, play_spotify, hang-up, Spotify opened by link); chat log shows every row | `native/ios/WakeOn/SimpleView.swift`, `native/ios/ChatUI`, `native/ios/WakeOn/VoiceSessionController.swift` |
| 2026-11-12 | 3652571 | Action Button cold start not slower with the live screen | latency.jsonl: 1 cold start vs 18 earlier cold starts | phone | First frame 140 ms (earlier median 266); mic live 543 ms (earlier 248–530, already rising since Nov 5); the wait was iOS foregrounding plus an audio engine restart, not drawing. One sample: not conclusive | `native/ios/WakeOn/SimpleView.swift`, `native/ios/WakeOn/VoiceSessionController.swift`, `native/ios/WakeOn/HotAudioDevice.swift` |
| 2026-11-12 | 3652571 | Live call screen on the Simple tab: orb, chat view updating as the call happens, Mute/End | `--demo-call` with your real market/weather capture, screenshots at 17 s and 39 s | sim | Web search row running with "Searching the web…", then done; answer streams in and the view follows it | `native/ios/WakeOn/SimpleView.swift`, `native/ios/ChatUI`, `native/ios/WakeOn/VoiceSessionController.swift` |
| 2026-11-12 | 3652571 | Live chat shows the same rows as the saved log for a call | unit test `LiveChatTests` | sim | Pass | `native/ios/ChatUI/CaptureReplay.swift`, `native/ios/WakeOn/CallCapture.swift` |
| 2026-11-12 | 3652571 | Wake On unit tests (67) and Chat Lab UI tests (5) | unit and UI tests | sim | All pass | `native/ios/WakeOn`, `native/ios/Tests`, `native/ios/ChatUI`, `native/ios/ChatLab`, `native/ios/ChatLabUITests` |
| 2026-11-12 | 7317e33 | Chat log page shows a call in Lobby's chat view (capture tool rows, older calls as lines) | phone, by you: opened your chat history | phone | Works | `native/ios/WakeOn/ChatLogsView.swift`, `native/ios/ChatUI` |
| 2026-11-12 | 7317e33 | Chat log page shows a call in Lobby's chat view | simulator screenshot with the phone's real logs; unit tests `ChatLogTranscriptTests` | sim | Opens at your last message; markers, timings, tool rows; tests pass | `native/ios/WakeOn/ChatLogsView.swift`, `native/ios/ChatUI` |
| 2026-11-12 | 7317e33 | Cold launch not slower after adding MarkdownView to Wake On | Instruments App Launch, 4 runs vs 3 on the build from b4feb51 | phone | 525–655 ms to first frame vs 538–679 ms before; static runtime init +1 ms | `native/ios/scripts/generate-project.py`, `native/ios/ChatUI`, `native/ios/WakeOn/WakeOnApp.swift` |
| 2026-11-12 | 7317e33 | Wake On unit test suite | unit tests (66) | sim | All pass | `native/ios/WakeOn`, `native/ios/Tests`, `native/ios/ChatUI` |
| 2026-11-12 | 7317e33 | Chat Lab UI test suite after moving the chat view to ChatUI | UI tests (5) | sim | All pass | `native/ios/ChatLab`, `native/ios/ChatLabUITests`, `native/ios/ChatUI` |
| 2026-11-12 | 09dd4ad | Chat Lab replays real captures: tool rows for web search, play_spotify and opening Spotify; filler and answer in separate bubbles | simulator screenshots of both real calls; UI test `ChatLabCaptureTests` on the sample | sim | As described; test passes | `native/ios/ChatUI/CaptureReplay.swift`, `native/ios/ChatLab/LabCaptureLibrary.swift` |
| 2026-11-12 | 09dd4ad | Captures reach Chat Lab on the phone | `scripts/pull-call-captures.sh --lab` | phone | 2 captures copied; shown under Real calls (not opened on the phone by Claude) | `native/ios/scripts/pull-call-captures.sh` |
| 2026-11-12 | b4feb51 | Real calls are captured in full, including the Spotify open and how it opened | 2 real calls by you, pulled and read | phone | Server, client and app events present; `spotify_opened` = universal_link | `native/ios/WakeOn/VoiceSessionController.swift`, `native/ios/WakeOn/OpenAILiveVoiceProvider.swift`, `native/ios/WakeOn/SpotifyPlayer.swift`, `native/ios/WakeOn/CallCapture.swift` |
| 2026-11-12 | b4feb51 | Capture file format: order, times, append after save, deleted with its log | unit tests `CallCaptureTests` (5) | sim | All pass | `native/ios/WakeOn/CallCapture.swift`, `native/ios/WakeOn/ChatLogStore.swift` |
| 2026-11-12 | 4534ad1 | Wide tables stay inside the bubble; Expand opens the full message | UI test `testExpandOpensWideTableInFull`; screenshots | sim, phone | Pass; contained on ours and exyte | `native/ios/ChatUI/ChatMarkdown.swift`, `native/ios/ChatUI/ChatTranscriptView.swift` |

## Not verified yet

| Since | What | Why not |
| --- | --- | --- |
| 2026-11-12 | How the live call screen looks and scrolls in a real call; a Hey Lobby call | Waiting on your verdict; only an Action Button call so far |
| 2026-11-12 | Action Button time to mic live, with more samples | One cold start so far (543 ms, at the top of the earlier range); warm starts not measured yet |
