# Wake On iOS spike

Native SwiftUI + AVAudioEngine + Sherpa ONNX prototype. No OpenAI connection,
API key, Python runtime, or network service is used by the app.

Enable listening, say **Hey Pixie**, and keep speaking. The actual Sherpa model
emits a wake event. The app immediately hands a snapshot to its UI, retains
**up to two seconds before detection plus three seconds after detection**, and
lets you replay the result. Detection pauses after a wake until explicitly
rearmed. The microphone remains active until Disable listening or Play captured audio is
tapped. Replay uses a normal media-playback session, avoiding the quieter output
of measurement mode; Listen for another wake restarts microphone capture.

## Background listening options and battery

Four **Listening options** on the main screen, all on by default:

- **Keep listening while other audio plays** (`.mixWithOthers`). Spotify, YouTube and other
  media apps play alongside the listener instead of interrupting it. The microphone also
  hears them.
- **Full sound for other apps.** While sharing, the listener uses iOS's default audio mode
  instead of measurement mode. Measurement mode switches off system processing for the
  whole route, so other apps lose their EQ, loudness and spatial effects. With this on,
  Spotify sounded identical to listening off, and "Hey Lobby" was still detected over
  music (one detection so far).
- **Resume after calls, Siri and alarms.** On an interruption, a route change or an audio
  service reset, the listener stops with the reason recorded. It restarts when iOS
  reports the interruption ended (retrying for ~30 s in the background), shortly after a
  route or service change, or when the app is next active. If it is still paused while
  the app is in the background, a "Listening paused · tap to resume" notification is posted
  at once and removed when listening is back. A voice call cancels a pending resume and
  restarts the listener when it ends.
- **Use iPhone microphone with headphones** (`.allowBluetoothA2DP` and the built-in
  microphone as preferred input). Bluetooth headphones stay in high-quality playback
  instead of switching to call quality.

With sharing off, the listener is exclusive: media apps interrupt it, and it cannot restart
itself from the background. Spotify and YouTube both end their interruption with
`shouldResume=false`, and iOS refuses to activate an exclusive session from the background
(`'!int'`, cannot interrupt others). It resumes after the notification is tapped or the
app is opened. Calls and alarms usually end with `shouldResume=true`; that path is not
yet tested on the device.

**Battery use** (from the Wake listener section) records each listening session and voice
call: the app's own power from the kernel's energy counter (`task_power_info_v2`), CPU,
CPU wake-ups, battery drop while unplugged, wakes detected and why the session ended.
It also stores Apple's daily MetricKit reports. Sessions are kept in
`Documents/battery-sessions.json`, and the running one in `battery-current.jsonl`.
The app's figure excludes the microphone hardware and iOS's audio service; battery drop
over long unplugged sessions includes them. Measured on an iPhone 17 Pro with the screen
locked: ~8–11 mW for the app, ~0.24 % of one core, ~27 wake-ups/s, and less than 1 %
battery in 73 minutes.

## Important iOS boundary

This is a foreground-started microphone session that continues in the background
using `UIBackgroundModes = audio`. A background wake changes the running app's
state and can deliver a **silent local notification**. The user taps it to bring
the app forward; the app cannot automatically foreground itself, unlock the
phone, or relaunch after force-quit/reboot. Notification permission is optional.
Without it, open Wake On manually to find the handoff.

Audio interruptions, actual microphone or input-format changes, and media service
resets stop the listener, and the reason is recorded. With **Resume after calls, Siri
and alarms** on (the default), it restarts by itself afterwards; with it off, you
enable listening again. Session-category and output-only notifications leave listening
active when the input and running audio engine are unchanged. iOS may suspend the app
during a long interruption, such as a phone call; in that case the listener resumes
when iOS delivers the end of the interruption or the app is next opened. It does not
promise continuous Siri-like operation or App Store acceptance.

## Open on your iPhone

Prerequisites: full Xcode with an iOS SDK, a connected iPhone on iOS 17 or newer,
and an Apple development signing team configured in Xcode.

```sh
cd native/ios
./scripts/setup.sh
open WakeOn.xcodeproj
```

The setup script downloads the pinned official Sherpa **1.13.4** iOS libraries
(including ONNX Runtime **1.27.0**), verifies the archive SHA-256, and copies the
same chunk-8 model used by the Python app. Downloaded libraries and model files
are ignored by Git. The project is generated using Python's standard library;
XcodeGen and CocoaPods are not needed. Re-running the generator replaces project
settings, so set your development team in Xcode **after** setup.

1. Select the **WakeOn** scheme and your iPhone as the destination.
2. In Signing & Capabilities, select your development team. Change the bundle ID
   if your signing account requires a unique one.
3. Enable Developer Mode on the phone if Xcode requests it, then Run.
4. Tap **Enable listening** and permit microphone access. Allow notifications if
   you want the tap-to-open route.
5. Leave the app or lock the screen, then say “Hey Pixie” followed immediately by
   a short sentence. Wait three seconds after detection.
6. Tap the notification or reopen Wake On. Look for **Detected in background**
   and replay the clip. It should include the wake phrase and following speech.
7. Tap **Listen for another wake** to repeat. Tap **Disable listening** when done.

On device, check quiet/noisy rooms, locked-screen operation after several
minutes, speaker and Bluetooth routes, calls/Siri interruption, and battery use.
Simulator success does not establish those hardware behaviors.

## Build and test in the simulator

The machine's default `xcode-select` may point at Command Line Tools. Set the
full Xcode directory for these commands without changing the global selection:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun simctl list devices available
# Boot an iPhone in Simulator, or: xcrun simctl boot <device-UUID>
xcodebuild -project WakeOn.xcodeproj -scheme WakeOn \
  -configuration Debug -sdk iphonesimulator -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WakeOn.xcodeproj -scheme WakeOn \
  -destination 'platform=iOS Simulator,id=<device-UUID>' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

Twelve XCTest checks cover voice turn detection and the Live session request, plus ring wraparound, early activation, actual-model wake
and exact handoff samples, ten seconds of silence, streaming 48→16 kHz
resampling, direct capture from the first sample through exactly five seconds, and harmless versus capture-invalidating audio-route changes.

A positive fixture is needed for model tests. Setup uses the local approved
`recordings/positive/positive-001-quiet.wav` when available. You can instead set
`WAKE_FIXTURE=/path/to/your-hey-lobby.wav` when running setup. Recordings stay
untracked. If none exists, setup creates a silent placeholder so live microphone
builds work; the positive detector tests will correctly fail until a real
fixture is supplied. Use mono 16 kHz WAV for the test corpus.

With a booted simulator and a Debug build:

```sh
python3 scripts/validate-simulator.py --scenario foreground
python3 scripts/validate-simulator.py --scenario background
python3 scripts/validate-simulator.py --scenario silence
```

Use `--device <UUID>` if multiple simulators are booted. A first-run notification
prompt must be handled manually; notification delivery is not asserted by these
scripts. The background scenario starts microphone capture in the foreground,
launches Simulator Safari, then sends the recorded fixture through the real
Sherpa detector on a paced worker timer. **It substitutes detector input for
microphone samples; it does not prove the simulator microphone heard speech.**

Every run gets a unique ID so stale reports cannot pass. Positive runs assert:

- The actual detector returns `HEY_LOBBY`.
- The app is in the expected foreground/background state when the wake is handled.
- The AVAudioEngine remains running.
- The captured 80,000 float samples equal the original source slice exactly.
- Preroll and post-wake spans are exactly 32,000 and 48,000 samples.

Scripts terminate the test app afterward, including on failure. Pass
`--keep-running` to inspect a successful result manually; disable listening when
done. `--output path.json` preserves the metadata report. The app keeps audio
only in memory. Debug builds write diagnostic metadata to Documents; they do not
write captured audio. Test launch arguments are disabled in Release builds.

## Action button recording and latency

**Start recording** is an App Shortcut. On iPhone, open the app once, then select
Settings → Action Button → Shortcut → Wake On → Start recording. Hold the button,
speak, and replay the five-second handoff. This foreground intent opens Wake On;
iOS may require an unlock. It does not implement locked-screen background initiation.
The existing background wake listener remains available separately.

The shortcut and Record now button use one shared microphone owner. Direct capture
bypasses model loading and wake detection, starts at the first converted sample,
and stops the microphone after 80,000 samples. Repeated requests during a capture
join that recording. If the wake microphone is already running, direct recording
reuses it. A readiness haptic is requested only after actual samples arrive.
The handoff is an in-memory object; this MVP does not send it to a voice backend.

Release and Debug builds write metadata-only `Documents/latency.jsonl`, available
through **Export latency traces**. Retention rotates at about 4 MB, retaining one
previous file. Captured speech is never included in traces. Each run contains:

- Run/process IDs, build, OS, device family, first/subsequent request number,
  invocation type, source, fixture/microphone input, application state and outcome.
- Monotonic offsets for permission, model preparation when applicable, audio session
  activation, engine setup/start, first callback, first converted samples, ready
  state publication, haptic request, wake detection, handoff publication and stop.
- Actual input rate/channel count, first callback size and host timestamp age,
  actual I/O duration/input latency, callback count, maximum copy time, mean/maximum
  worker queue and conversion time, and missing input frames from sample timestamps.
- App lifecycle transitions and separate playback runs with playback-session timing.

`ready_ui` / `handoff_ui_ready` mean main-thread state publication, not a measured
screen refresh. A haptic request does not measure physical haptic delivery. Timing
begins at `perform()` or the in-app request; **the physical button press, iOS launch
scheduling and unlock time before perform are not measured**. `ageSinceAppInitMs`
provides context since SwiftUI app initialization, not a true process-launch timer.
The intentional five-second recording is included in handoff latency. Simulator
microphone callback sizes and scheduling are not representative of an iPhone.

```sh
python3 scripts/validate-simulator.py --scenario direct --output validation/action-direct.json
python3 scripts/validate-simulator.py --scenario direct-live --output validation/action-direct-live.json
python3 scripts/validate-simulator.py --scenario direct-reuse --output validation/action-direct-reuse.json
python3 scripts/summarize-latency.py validation/*.latency.jsonl
```

The direct Debug harness invokes the **real `StartRecordingIntent.perform()`** in
the installed app. `direct` feeds a paced fixture and checks every output sample;
`direct-live` exercises AVAudioEngine microphone callbacks and resampling. Both also repeat the intent during capture to check that it joins the existing
recording. `direct-reuse` starts wake listening, then uses the same intent with
the already-active microphone. These checks assert trace identity, readiness, handoff and microphone shutdown. They do not
exercise iOS Shortcuts dispatch or a physical Action button. Harness invocations
are labeled `intent_handler_harness` and must not be pooled with system runs.

On the installed iOS 26.5 simulator, Shortcuts discovers our App Shortcut but fails
before intent execution with `Couldn't find AppShortcutsProvider`. Similar failures
with Apple's sample app are reported on the
[Apple Developer Forums](https://developer.apple.com/forums/tags/simulator?page=2&sortBy=created&sortOrder=DESC).
This is a reported runtime issue, not proof that device dispatch works. Validate
the assigned Action button on iPhone. Test-only launch arguments do not exist in
Release builds. The summary script groups fixtures, platforms, build/OS, request
order and microphone reuse separately, and reports nearest-rank p50/p95/max with n;
a handful of runs is not a stable latency benchmark.

## Code map

- `WakeDetector.swift`: small native C-API wrapper; same model and settings as Python.
- `AudioConverter.swift`: persistent mono 16 kHz converter for incoming buffers.
- `HandoffBuffer.swift`: bounded preroll and exact post-trigger capture.
- `WakeController.swift`: microphone/session lifecycle, serial inference, handoff,
  playback, notifications, and Debug fixture runner.
- `StartRecordingIntent.swift`: foreground App Intent and discoverable App Shortcut.
- `LatencyTrace.swift`: monotonic milestones, signposts and bounded JSONL export.
- `ContentView.swift`: listener controls and handoff inspection.
- `Visualizer/`: animated voice visualizers for calls (see below).

### Voice visualizer

`VoiceVisualizer()` draws the default sky orb from live call audio. It needs no
setup: `HotAudioDevice` copies the microphone and the assistant's playout into
`VoiceAudioTap.shared`, and `VoiceSignal.live` turns that into loudness, a
32-band spectrum, a bounce spring and a "thinking" state (a pause after you speak).

```swift
VoiceVisualizer()                                   // sky orb, live audio
VoiceVisualizer(style: .waveOrb, palette: .ocean)   // any style and color preset
VoiceVisualizer(signal: .simulated())               // SwiftUI previews
```

Styles: sky orb, wave orb, bouncing pills, particle sphere, ring tunnel, Saturn,
particle terrain, particle torus, radial spectrum. The two orbs are SwiftUI
Metal shaders (`VoiceOrbShaders.metal`), so Xcode needs its Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`, once). The others use `Canvas`.

The call screen shows the chosen style while connecting or live. **Visualizer**
in the voice section opens a gallery that plays a recorded two-voice
conversation (`Resources/VisualizerSamples`) to compare styles and pick one. In
Debug builds, launch with `-visualizer-gallery -visualizer-autoplay` to open it
directly. The browser prototype these were designed in lives in
`prototypes/voice-visualizer` at the repository root.

The future voice adapter can consume the initial `AudioHandoff` at wake and the
subsequent samples at the same serial processing boundary. This prototype uses a
fixed three-second post-wake capture for inspection; it is not yet an unbounded
voice streaming session or a durable recording store.

## Validation evidence

See `validation/` for fixture reports and the validation notes. A simulator
background pass is separate from real-device microphone, battery, suspension,
notification-tap, and locked-screen validation.

## Renaming the assistant

The name lives in one place, `Agent` ([Shared/Agent.swift](Shared/Agent.swift)): the app's text,
the voice instructions and the wake phrase ("Hey <name>") all read it. The wake phrase is turned
into the model's sounds at start from the bundled pronouncing dictionary (`Resources/lexicon.txt`,
see `WakeOn/WakePhrase.swift`), so any name in it works with no new keyword file. There's no
setting for it yet; to try another name, launch with `-agentName Nova`. Info.plist, the App
Shortcut titles and the server's copy say "Pixie" on their own. The wake threshold was tuned on
"Hey Lobby" recordings, so a new name may need its own.

## Realtime voice: Talk to Pixie

Architecture, latency design and every experiment: [docs/ios-voice-latency.md](../../docs/ios-voice-latency.md).
Raw measurements: [docs/measurements/2026-10-25-ios-voice](../../docs/measurements/2026-10-25-ios-voice/README.md).

**Talk to Pixie** starts a two-way voice conversation with OpenAI's `gpt-live-1`
over WebRTC, straight from the phone. There is no relay server. Questions that
need current information are delegated to `gpt-6.1-terra` with hosted web
search. This uses an **OpenAI API key** and is billed per use to that API
account, not to a ChatGPT subscription. A WebRTC session bills at least
15 seconds of audio.

Setup:

1. `./scripts/setup.sh` downloads WebRTC M153 (`stasel/WebRTC` 153.0.0, SHA-256
   checked) into `Vendor/` alongside Sherpa.
2. Give the app a key. Either paste it under **OpenAI API key** in the app, or,
   in a Debug build, set `OPENAI_API_KEY` in the launch environment (Xcode:
   Product › Scheme › Edit Scheme › Run › Environment Variables). The app moves it
   into the Keychain on first use, so later launches by iOS still have it. The
   key is never written into the app bundle. Do not give this build to anyone else.
3. Settings › Action Button › Shortcut › Pixie › **Talk to Pixie (fast start)**.
   It starts connecting before iOS brings the app forward, about 600 ms sooner
   than plain **Talk to Pixie**, which iOS runs only ~700 ms after the app is on
   screen. **End Pixie call** is also available. The wake listener pauses during
   a call and resumes afterwards.

Audio comes from `HotAudioDevice`, the app's own voice-processing `AVAudioEngine`
plugged into WebRTC as an `RTCAudioDevice`. It is armed when a call is requested,
in parallel with the network, and built in the background for fast start. Each
next call's peer, offer and ICE candidates are prepared ahead of time; a press
sends the offer within a millisecond. "Listening" appears as soon as the microphone is capturing
(~300–380 ms after a fast-start press). Speech is buffered on the phone until OpenAI
is ready, then sent at 4× real time until the stream is live. Debug builds save each
backlog as `Documents/backlog-<time>.wav`.

Every call writes three kinds of traces to `Documents/latency.jsonl`, read with
`scripts/summarize-latency.py`:

- `voice_setup:<trigger>`: trigger → key → WebRTC offer → ICE → HTTP (DNS,
  connect, TLS, server wait) → answer applied → connected → data channel →
  `session.started` → first audio packet. It includes cold-launch age.
- `voice_turn`: you stop talking → first reply transcript → reply audio heard.
  Delegated turns continue through each backend stage (web search, first token,
  completed) to the spoken answer. Speech start and stop come from WebRTC's
  cumulative audio energy, sampled every 50 ms. Round trip, jitter buffer and
  concealment are attached.
- `voice_probe:greeting|search`: scripted requests for the simulator.

Debug launch arguments for measurement: `--talk [greeting|search]`,
`--end-after <s>`, `--calls <n>` (repeat calls in one process: the warm path),
`--no-delegation`, `--no-web-search`, `--effort <low|none|default>`,
`--ice-quiet <ms>` (0 waits for complete gathering), `--no-warm-audio`,
`--builtin-audio` (WebRTC's own iOS audio instead of `HotAudioDevice`),
`--no-prepare` (no call prepared ahead of time). URLs:
`wakeon://talk?probe=greeting`, `wakeon://end`. Debug builds also append status
lines to `Documents/voice-console.log`; attaching `simctl launch --console-pty`
can stall the app's main thread.

In the simulator, the Mac's speakers feed its microphone without echo
cancellation. The assistant's own voice is then detected as user speech, and
there are spurious `voice_turn` traces. Measure turn latency on a device.
Measurements are in `docs/notebook/2026-10-25-ios-realtime-voice.md`.

