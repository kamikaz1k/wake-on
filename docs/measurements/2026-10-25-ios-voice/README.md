# iOS realtime voice measurements, 2026-10-25

Raw data behind [iOS realtime voice: architecture and latency](../../ios-voice-latency.md)
and the [notebook entry](../../notebook/2026-10-25-ios-realtime-voice.md).

- **Device:** iPhone 17 Pro (iPhone18,1), iOS 26, Wi-Fi, network round trip ≈ 54 ms.
- **Simulator:** iPhone 17 Pro, iOS 26.5, on the Mac's network.
- **Service:** OpenAI `gpt-live-1` over WebRTC, delegating to `gpt-5.6-terra` with web
  search.

## Files

| File | What it is |
|---|---|
| `device-calls.csv`, `simulator-calls.csv` | One row per call, from the logs below. Regenerate with `native/ios/scripts/summarize-voice-log.py logs/device/*.log > device-calls.csv`. |
| `device-traces.jsonl`, `simulator-traces.jsonl` | The app's structured `latency.jsonl` traces (`voice_setup:*`, `voice_turn`, `voice_probe:*`, `wake_listener`, `app_intent`). Read them with `native/ios/scripts/summarize-latency.py`. Renamed because the repository ignores `latency.jsonl`. |
| `logs/device/*.log`, `logs/simulator/*.log` | Debug `voice-console.log` copies, numbered in the order the experiments ran. |

The backlog recordings (the user counting "one, two, three", Int16, 48 kHz, mono) are in
`recordings/ios-voice-backlog/`, which is git-ignored. They are voice recordings, so they
are not committed.

## Metric definitions (milliseconds from the trigger)

The trigger is the intent's `perform` for Action Button runs, the tap for in-app runs, and
`onAppear` for launch-argument runs.

| Column | Meaning |
|---|---|
| `http_request_begin_ms` | The SDP offer is sent to `POST /v1/live/sessions`. |
| `server_wait_ms` | Request sent → first response byte (`URLSessionTaskMetrics`). This is OpenAI's share. |
| `remote_description_set_ms` | The SDP answer has been applied. |
| `ice_connected_ms`, `data_channel_open_ms` | Network path up; `oai-events` channel open. |
| `session_started_ms` | `session.started` received: the server is ready. |
| `first_frame_after_trigger_ms` | First display refresh after the trigger, while not in the background (newer logs only). |
| `mic_live_ms` | The microphone is capturing. With local buffering, speech counts from here. Newer logs only. |
| `reaching_openai_ms` | `session.started` and the first microphone packet sent. In logs before buffering, this was printed as "listening". |
| `backlog_ms` | Buffered audio sent at 4× once the server was ready. |
| `after_app_launch` | The call started in a newly launched process (cold). |

Caveats:
- In the simulator, the Mac's speakers feed its microphone with no echo cancellation, so
  simulator turn traces and some "user said" text are the assistant's own voice.
- OpenAI's server wait varied from 160 ms to 1,241 ms between calls. Compare runs by
  the app's own segments, not only by totals.

## Log index

### Device

| Log | Experiment |
|---|---|
| 01 | WebRTC built-in audio with timing marks; shows applying the answer waiting ~400 ms for iOS audio. |
| 02 | Built-in audio A/B baseline (826–874 ms to reaching OpenAI on that run). |
| 03 | First `HotAudioDevice`: no microphone packets (the engine stopped after starting). |
| 04 | Device call tracing: WebRTC asked to start before the engine was running. |
| 05 | Engine configuration change and route changes traced. |
| 06 | Restart-on-configuration-change fix: reaching OpenAI at 726 ms. |
| 07, 08 | Prepared call vs not: the request is sent at 28 ms vs 65–89 ms. |
| 09 | Fast trigger path (key cache, synchronous offer): request at 0.5 ms; warm calls reach OpenAI at ~545 ms. |
| 10–12 | Action Button, normal intent: iOS starts `perform` ~700 ms after the app is on screen. |
| 13 | Fast-start intent v1: `perform` 60 ms after launch. |
| 14 | Audio engine built in the background: audio ready ~510 ms. |
| 15 | Microphone started at will-enter-foreground: audio ready 295 ms. |
| 16, 17 | Local buffering: "one" lost twice, then captured (with a WAV). |
| 18 | "Listening" from the first frame, in-app. |
| 19, 20 | Session reuse; buffering wrongly ended by the warm-up's `stopRecording`, then fixed. |
| 21, 22 | Fast-start presses counting at first sight of the app; one press with no reply. |
| 23 | Server event counts: speech transcribed, no reply events. |
| 24, 25 | Pause vs stop the engine between calls: no difference (~287 ms). |
| 26 | Always-reply instruction: both presses got replies. |

### Simulator

| Log | Experiment |
|---|---|
| 01, 02 | Cold and warm calls with and without Responses delegation. |
| 03, 04 | Delegated web-search probe; reasoning effort `low` vs `none` (last run kept). |
| 05 | Spoken turn using the Mac's `say` through the simulator microphone: reply 1,359 ms after speech ended. |
| 06, 07 | First batch after the warm-up, quiet-ICE and background-audio changes (first warm-up version deadlocked). |
| 08–11 | ICE: wait for "complete" vs send after 25 ms with no new candidates. |
| 12–17 | WebRTC warm-up including an audio transceiver, on and off. |
| 18–20 | UI updates batched during set-up. |
| 21 | Local buffering mechanics (simulator microphone too quiet to transcribe). |
