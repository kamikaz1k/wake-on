# Action button prototype validation — 2026-10-22

Release build 2 was signed, installed and launched on Kaiser's iPhone (iOS 26.6.2).
The user confirmed that the assigned Action button opens Wake On and completes
the handoff. Retrieved device traces contain three successful App Intent captures
with exactly 80,000 samples each and zero missing input frames.
No Realtime backend is integrated. Recording remains an in-memory five-second handoff.

## Passed

- Eight XCTest checks, zero failures, using iPhone 17 Pro simulator / iOS 26.5 / Xcode 26.6.
- Installed Debug app, real StartRecordingIntent.perform() handler, fixture input:
  exactly 80,000 samples, start frame zero, complete source-to-handoff sample equality.
- Real AVAudioEngine microphone input: first callback → converter → five-second
  handoff → main-thread publication → microphone shutdown; zero missing frames.
- Duplicate intent invocation joins the same run without resetting its buffer.
- Switching from a live wake listener reuses its microphone and bypasses model setup.
- Denied microphone permission returns a failure trace and never starts the engine;
  the simulator's existing microphone permission was restored afterward.
- Existing foreground wake, background wake and silence rejection regressions.
- UI inspection showed Audio handoff ready, DIRECT RECORDING and 5.00 seconds;
  microphone control had returned to Enable listening.

## Observed timings

Single observations from the intent-handler harness. These are not estimates of
physical button latency and are not stable p50/p95 benchmarks. The handoff time
includes the deliberate five-second audio capture. Simulator audio callbacks were
approximately 100 ms despite a smaller requested I/O/tap buffer.

| Path | Intent entry → first samples | Intent entry → handoff published | Missing input frames |
| --- | ---: | ---: | ---: |
| direct-live | 427.2 ms | 5441.7 ms | 0 |
| direct-reuse | 90.5 ms | 4997.1 ms | 0 |

## System dispatch limitation

Shortcuts on the simulator discovers Start recording but fails before executing
it, with LNActionForAutoShortcutPhraseFetchError: Couldn't find AppShortcutsProvider.
Reproduced again after explicit updateAppShortcutParameters registration. Captured
in action-shortcuts-simulator-error.txt. Similar failures with Apple's sample
project are reported at:
https://developer.apple.com/forums/tags/simulator?page=2&sortBy=created&sortOrder=DESC

Thus the full system Shortcuts/Action button dispatch path has **not** passed in
this simulator. Harness passes validate the actual intent method and audio
handoff, while bypassing that failing system dispatch boundary. Device testing
must establish assigned Action button operation, cold launch, unlock requirements,
hardware latency and readiness cue behavior.

## Reproduce and inspect

See ../README.md for simulator commands, device assignment and trace semantics.
Run ../scripts/summarize-latency.py on the *.latency.jsonl files. Metadata groups
keep fixture/hardware, harness/system, build/OS, request order and microphone reuse
separate. Audio and the pre-perform physical button timestamp are not in traces.

## Confirmed device trial

The user confirmed successful assigned Action button operation on iPhone. Three
real App Intent runs recorded first usable samples at 328.2, 293.0 and 570.1 ms
after intent entry. All were in the same already-running app process; these are
not cold process-launch measurements. Each captured five seconds, published the
handoff, and stopped the microphone. Every run recorded zero missing input frames.
Mean resampling time was 0.11–0.13 ms per callback.

The device delivered 4,800-frame blocks at 48 kHz (100 ms), despite the requested
256-frame tap and 10 ms I/O buffer. Engine start took about 146–152 ms; audio-session
activation varied from 46–231 ms. These are the main measured contributors to
readiness latency. No physical button press, unlock, or OS scheduling before
perform() is timed. Locked-screen and force-quit/cold-start behavior remain unverified.

The three original metadata traces are in action-device.latency.jsonl.
