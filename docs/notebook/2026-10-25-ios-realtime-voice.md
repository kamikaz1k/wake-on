# iOS realtime voice: GPT-Live over WebRTC, instrumented

- **Date:** 2026-10-25
- **Status:** working on an iPhone 17 Pro (iOS 26) from the Action Button; see the device section
- **Question:** how fast can an Action Button press reach a live voice conversation,
  and where does the time go?
- **Summary:** [iOS realtime voice: architecture and latency](../ios-voice-latency.md);
  raw data in [measurements/2026-10-25-ios-voice](../measurements/2026-10-25-ios-voice/README.md)

## Decision

A ChatGPT plan cannot pay for third-party realtime voice. OpenAI's Sign in with
ChatGPT is limited to approved partners and covers text Responses only. Amp, a launch
partner, bills voice to its own credits. Codex's subscription voice needs a desktop
host. See the [superseded plan](2026-10-20-ios-subscription-voice-plan.md).
Wake On therefore calls the API directly from the phone, with the repository's
`OPENAI_API_KEY` kept in the Keychain:

- `POST https://api.openai.com/v1/live/sessions` with
  `{session, transport: {type: "webrtc", sdp}}` returns `{session.id, transport.sdp}`.
- `gpt-live-1`, voice `marin`, Responses delegation to `gpt-5.6-terra` with
  `web_search`, reasoning effort `low`.
- Events arrive on the `oai-events` data channel: `session.started`, transcript
  deltas with `start_ms`/`end_ms`, `session.delegation.created`, `response.event`
  (nested Responses stream), `session.usage.updated`, `session.closed`. GPT-Live
  has **no** speech-started/stopped or audio-started events, so the phone derives
  turns from WebRTC's cumulative audio energy (`media-source` and `inbound-rtp`
  `totalAudioEnergy`/`totalSamplesDuration`, sampled every 50 ms).

## Measurements (simulator, Mac network, RTT ≈ 54 ms)

Setup, milliseconds from trigger. Medians come from 2–6 launches each:

| Stage | First run | Final, cold launch | Final, warm |
|---|---|---|---|
| main thread free (`connect_task_begin`) | 265 | ~210 | ~15 |
| ICE gathering | 106 | ~35 | ~35 |
| OpenAI session creation (server wait) | 1,241 | 180–360 | 180–210 |
| apply answer (`setRemoteDescription`) | ~170 | ~45 | ~20 |
| ICE + DTLS connect | 154 | ~153 | ~155 |
| data channel open | 105 | ~110 | ~110 |
| **`session.started`** | **2,314** | **~840–900** | **~605–620** |
| first reply audio packet (greeting probe) | 2,880 | ~1,380–1,510 | ~1,180–1,320 |

Changes, each measured A/B:

1. **Audio activation off the critical path.** Activating the audio session took
   about 100 ms. It now runs on another thread while OpenAI creates the session.
2. **Send the offer when candidates stop arriving** (25 ms quiet), not at
   "gathering complete". Gathering fell from ~105 ms to ~35 ms and candidates from
   16 to 8. Connect time was unchanged: ~152 ms in both arms, over four launches.
3. **Warm WebRTC at launch.** A throwaway local offer/answer, including an audio
   transceiver, runs during app start-up, with manual audio on so it cannot touch
   the microphone. Cold `setRemoteDescription` fell from ~190 ms to ~45 ms. An
   earlier version raced the real call inside WebRTC and deadlocked; the call now
   awaits the warm-up (70–380 ms, hidden behind the first draw).
4. **TLS pre-connect** when the app becomes active. The session POST reused the
   HTTP/3 connection in every run.
5. **No UI publishing during setup.** Timeline rows are published once setup
   finishes, and network statistics at most twice a second.

OpenAI's server wait varied from 160 ms to 1,241 ms between calls; the slowest
came from the first call of the day. Delegation config changed it by no measurable
amount. What remains client-side is the cold-launch first draw (~200 ms) plus
network round trips: ICE and DTLS ≈ 3 RTT, the data channel ≈ 2 RTT.

**Spoken turn.** The Mac said "What is the capital of France?" into the simulator
microphone. From the end of speech, the reply transcript arrived after 1,280 ms and
reply audio after **1,359 ms**. Round trip was 54 ms and the jitter buffer 35 ms, so
the time is almost all server end-of-turn detection and generation.

**Delegated web search** (`voice_probe:search`, from the request):

| Stage | Before filler change | After |
|---|---|---|
| delegation created | 121 | 120–200 |
| spoken filler starts | 670 | 700–950 |
| web search completed | 1,208 | 1,420–1,780 |
| backend `response.completed` | 1,731 | 1,900–2,300 |
| **answer spoken (transcript)** | **2,932** | **2,070–2,500** |

At first the voice model spoke the answer about 1.2 s after the backend finished,
apparently letting a long filler run to its end. Telling it to say at most three
words while waiting cut that to 70–380 ms. Reasoning effort `none` against `low`
made no measurable difference in four runs, so `low` stays.

## Caveats

- In the simulator, the Mac's speakers feed its microphone without echo
  cancellation. The assistant's voice is counted as user speech, so many
  `voice_turn` traces are spurious (`no_reply`, `call_ended`). Turn latency needs
  a device.
- The Action Button path (`TalkIntent`, foreground) cannot be pressed in the
  simulator. Its launch-to-intent cost is recorded as `processAgeMs` and
  `connect_task_begin` on the device.
- The speech detector's thresholds (start 0.02, stop 0.012 RMS; hangover 0.5 s)
  are untuned for real rooms.

## Device: trigger → listening (iPhone 17 Pro, Wi-Fi, RTT ≈ 54 ms)

"Listening" means `session.started` has arrived **and** the first microphone packet
has left the phone; the app shows "Live · speak now" only then. Times are from the
first sign of a press (app launch for a closed app, the intent itself otherwise).

| Version | App closed | App in background |
|---|---|---|
| WebRTC built-in audio, normal intent | — | ~1,700 |
| Normal intent, all app-side cuts below | 1,559 | 1,542 |
| `Talk to Lobby (fast start)` | ~955 | ~917 |
| + audio engine built in the background | ~1,025 (server 455) | 859 (server 462) |
| **+ microphone started at will-enter-foreground** | **~1,001 (server 355)** | **630 (server 238)** |

Background press, final build: offer sent 0.3 ms → OpenAI 238 ms → answer applied
2 ms → ICE/DTLS 153 ms → data channel + `session.started` 170 ms. At OpenAI's
typical ~200 ms this is ≈ 525 ms, of which the app is ≈ 3 ms. A closed-app press
adds ~67 ms of process launch and ~98 ms to build the offer, which cannot exist
before the process does (≈ 710 ms at a typical server time).

What was removed, in order of size:

1. **iOS's ~700 ms intent hand-off.** A normal `openAppWhenRun` intent runs ~700 ms
   after the app is on screen (measured identically for closed and background
   apps). `FastTalkIntent` declares `supportedModes: [.background, .foreground(.dynamic)]`,
   so iOS runs it ~60 ms after launch; it sends the offer, then calls
   `continueInForeground(alwaysConfirm: false)`.
2. **WebRTC's iOS audio start (~750 ms on the device).** Voice-processing set-up ran
   inside `setRemoteDescription`, after the network. `HotAudioDevice` (an
   `RTCAudioDevice` over `AVAudioEngine` with voice processing) is armed at the
   trigger in parallel; WebRTC's start calls only flip flags. Applying the answer
   fell from ~410–580 ms to 2–4 ms. Its parameters are cached because
   `AVAudioSession` getters block while the session is being activated elsewhere.
3. **Audio in the background.** iOS allows activating the session and building the
   voice-processing engine in the background, and even starting it at
   `UIScene.willEnterForegroundNotification`. Audio is ready ~295–355 ms after
   the intent, before OpenAI answers. The engine stops itself once after start
   (configuration change) and is restarted in ~15 ms.
4. **Prepared call.** Peer, offer and ICE candidates are built at launch, on
   becoming active and after each call (no cost, no microphone), and the trigger
   handler sends the offer synchronously before any UI work: request at 0.3–4 ms
   instead of 65–89 ms. The key is cached in memory.
5. Smaller: offer sent after 25 ms without new candidates (~70 ms), WebRTC warmed
   at launch, TLS pre-connected, no SwiftUI publishing during set-up.

Spoken turns on the device (you stop talking → reply heard): 938–1,624 ms, almost
entirely server end-of-turn detection and generation.

## Listening before the connection exists

`HotAudioDevice` captures from the moment its engine starts and buffers up to 10 s on the
phone. WebRTC is given no microphone frames until `session.started`. The backlog is then
fed to WebRTC at 4× real time (`catchUpSpeed`), and the stream switches to live audio
once it catches up. GPT-Live over WebRTC does not accept audio over the data channel,
so the backlog has to travel on the media stream as a short burst. "Listening" in the
UI now means "the microphone is capturing"; "audio reaching OpenAI" is reported
separately.

| Fast-start press | App closed | Background | Background |
|---|---|---|---|
| Listening (can talk) | 373 ms | 309 ms | 378 ms |
| Audio reaching OpenAI | 1,093 ms | 757 ms | 962 ms |
| Backlog sent | 900 ms of audio | 520 ms | 760 ms |
| Transcript of "one, two, three…" | "Two, three, four" | "Two, three, four" | **"1, 2, 3"** |

In the third press the saved backlog WAV holds near-silence for 0–300 ms, then
"one" at 350–700 ms. OpenAI transcribed it, so a burst at 4× is accepted from its
first frame. In the first two presses "one" was lost. The likely cause is speaking
within the first ~100–300 ms, while voice processing is still converging; this is
unconfirmed, because those presses have no WAV. Experiment: bypass voice processing
while buffering (nothing is playing yet, so there is no echo to cancel) and enable it
at `session.started`.

## Listening from the first frame

"Listening" is now set at the trigger, so it is on screen from the app's first frame
(`first_frame_after_trigger`, measured with a display link). The question becomes
whether the microphone is live before the user starts talking after that cue.
Supporting changes:

- Voice processing is bypassed while only buffering (no playback, so no echo) and
  enabled at `session.started`. Its warm-up can no longer swallow the first word.
- The voice-processing engine is kept between calls. `disarm` stops it and releases
  the session, but does not destroy it.
- When iOS launches the app in the background for the fast-start action, the app
  delegate builds the engine immediately.
- The session is activated only when it is not already active in voice-chat mode;
  repeating the activation cost 90–105 ms.
- Bug fixed: WebRTC calls `stopRecording` when the launch warm-up's peer connection
  closes, and that call used to end the call's local buffering.

Four fast-start presses, counting "one, two, three" the moment the app appeared
(times from the intent):

| Press | First frame | Mic live | Voice in WAV after mic live | Audio reaching OpenAI | Transcript |
|---|---|---|---|---|---|
| Cold | 105 ms | **248 ms** | 140 ms | 693 ms | "One, two, three" |
| Warm | 59 ms | 294 ms | 140 ms | 669 ms | none (see below) |
| Warm | 58 ms | 281 ms | 20 ms | 755 ms | "One, two, three" |
| Warm | 59 ms | 297 ms | 20 ms | 659 ms | "One, two, three" |

On a cold launch the microphone is live ~140 ms after the first frame; on a warm
press, ~225–240 ms after it. That is about one human reaction time, so in two warm
presses speech was already starting when capture began (the first 20 ms window is
loud). "One" was still recognised. A warm press re-prepared the kept engine (~50 ms)
at microphone start; that now happens in the background. That change is untested on
a press.

**Missing replies were the model, not the audio.** Per-call server event counts show
OpenAI transcribed the speech every time (`session.input_transcript.delta`) but sent
no `session.output_transcript.delta`. Across every logged press, GPT-Live rarely
answered counting or plain statements ("This is from the cold start", "Two, three,
four, five"), with or without the voice-processing bypass, but answered questions
within ~1 s. A one-line instruction ("Always reply when the user stops talking, even
if they only counted, tested the microphone or made a statement") fixed it: both
following warm presses got "Got it…". The first-turn reply time is not measured in
these calls, because the backlog burst confuses the energy-based turn detector.

**Pause instead of stop between calls: no gain.** Three back-to-back calls each:
pausing gave session ~43 ms + start ~240 ms, and stopping gave ~100 + ~180. The
microphone was live at ~287 ms either way, so stopping stays (it also frees the
hardware). Restarting the voice-processing I/O is the floor for an in-app press.

The remaining floor for a warm press is iOS: the foreground transition starts
~40 ms after the intent, and starting the voice-processing I/O unit takes ~180 ms.

## Next

- Holding the audio session ready while the app is open would remove the remaining
  ~150 ms engine start for in-app presses, at the cost of stopping other audio.
  Not done; it is a product decision.
- Tune the turn-detector thresholds on the device's echo-cancelled microphone.
