# 2026-08-03 — Native macOS AEC and single-owner microphone capture

- **Date:** 2026-08-03
- **Area:** Native audio, acoustic echo cancellation, wake detection
- **Status at end of entry:** Working spike; controlled sensitivity comparison remains
- **Related:** [Laptop speaker/microphone research](../research/laptop-speaker-barge-in.md), [native media protocol](../native-media-protocol.md)

## Problem

We wanted full-duplex conversation on a MacBook using its built-in microphone
and speakers. The user must be able to interrupt assistant playback, while the
assistant's own speaker output must not be mistaken for user speech. Wake On
should remain a backend-agnostic trigger and lifecycle library; the native
media path is an optional high-quality reference integration.

Server VAD alone cannot solve this. It receives the mixed microphone signal and
does not know whether speech came from the user or from assistant playback.
The client needs acoustic echo cancellation (AEC) with a playback reference.

## Starting state

- WebSocket interruption and item truncation already worked with headphones or
  an echo-cancelled input.
- A browser WebRTC spike provisionally validated the concept. A clean silent
  echo-only rerun produced no false speech starts, and the barge-in trial
  measured about 90.4 ms from remote speech detection to remote audio silence.
- WebRTC proved that laptop-speaker AEC was feasible, but a browser was not the
  preferred runtime shape for the native macOS library experience.

## Experiment 1: native voice-processing helper

We built a Swift helper around `AVAudioEngine`:

- enabled voice processing with `setVoiceProcessingEnabled(true)`;
- captured processed mono PCM from the input node;
- played 24 kHz assistant PCM through `AVAudioPlayerNode`, giving Apple's voice
  processor the output reference;
- exchanged framed binary PCM and lifecycle messages with Python over stdio;
- kept OpenAI networking, API credentials, wake routing, and conversation
  policy in Python.

The helper launches during delegate `prepare()`, before wake detection is
accepted. This keeps native device setup off the wake-to-response critical
path. A hardware smoke test reported:

| Observation | Result |
| --- | --- |
| Voice processing | Enabled |
| Capture format | 48 kHz mono |
| Playback format | 24 kHz mono |
| Initial cold setup observed | About 3.1 s |
| Later setup observations | About 1.0 s |
| Shutdown | Clean in the initial smoke test |

The helper reported approximately 0.02 ms output presentation latency. We do
not treat that value as total acoustic or device latency; it is too narrow a
measurement to support that conclusion.

The high-level input tap delivered roughly 100 ms capture frames even though a
20 ms buffer size was requested. This did not prevent the spike from working,
but direct Voice Processing I/O (`AUVoiceIO`) remains an option if capture
cadence becomes a measurable latency problem.

## Experiment 2: live built-in speaker and microphone trial

The native helper was connected to the existing OpenAI Realtime WebSocket
delegate. Python retained one second of processed native preroll and streamed
capture only while the conversation was active.

Direct observations from the live trial:

- assistant playback through the built-in speakers worked;
- the user successfully interrupted assistant playback;
- no obvious assistant-echo false interruption was observed;
- successful activations reached first assistant playback in roughly
  775–909 ms;
- after server VAD reported speech, local playback stopped in roughly
  0.17–0.51 ms in the inspected interruptions.

The last metric starts at receipt of the server event. It does not include the
time from physical speech onset to server VAD detection.

## Regression: wake phrase became less responsive

The user reported that “Hey Lobby” missed more often than before. The initial
native implementation had two independent clients opening the same physical
microphone:

```text
Mac microphone
├── sounddevice, 16 kHz → Sherpa wake detector
└── AVAudioEngine, 48 kHz → processed conversation capture
```

The logs could show successful detections but could not record attempted wake
phrases that were missed, so they did not provide a hit-rate denominator. Code
inspection confirmed the duplicate ownership and its startup order. We inferred
that device contention or voice-processing route/gain changes were the most
likely cause of the regression. This was a strong architectural hypothesis,
not a controlled causal measurement.

One earlier failed run also overlapped with a second Wake On process left open
by the development session. That separate source of microphone contention was
identified and removed before the later trials.

## Change: make the native helper the only microphone owner

We changed native mode to use one continuous capture stream:

```text
AVAudioEngine voice-processed capture, 48 kHz
├── linear resample to 16 kHz → Sherpa wake detector
└── original PCM → one-second preroll + active conversation stream
```

`NativeWakeAudioSource` exposes the 16 kHz branch to the existing wake harness.
`NativeMacMedia` retains the original processed frames for the delegate. Wake
detection and conversation media now share one continuous device timeline, and
native mode does not construct a `sounddevice` input stream.

Because the spike currently uses the system default native route, native mode
rejects `--device`, `--output-device`, and `--audio-file`. Supporting selectable
native devices is separate work and must not reintroduce multiple owners.

## Repeat trial after single-owner change

The first repeat produced five distinct wake activations. Observed activation
metrics were:

| Metric | Observed range |
| --- | --- |
| Wake detection → immediate feedback | Less than 0.7 ms |
| Wake detection → first assistant playback | 744–1,078 ms |
| Wake detector call | 3.70–11.79 ms in the displayed activations |
| Processed wake frame duration | 100 ms |

Some additional “Hey Lobby” utterances occurred while a conversation was
already active. Those were correctly sent to the active agent instead of
starting another activation; the wake harness deliberately owns only one
conversation at a time.

This repeat is encouraging but is not a sensitivity benchmark. We did not
record the exact number of phrases attempted while the harness was in its
listening state, nor replay identical audio through raw and processed paths.

## Shutdown issue discovered during the repeat

`Ctrl+C` also reached the Swift child process. The helper could exit before
Python sent its final playback-clear command, initially causing a broken-pipe
traceback. Suppressing the expected closed-pipe race fixed that symptom.

After the single-owner change, another shutdown edge appeared: if the child
exited while Python was blocked waiting on the native wake queue, no further
frame arrived to let the main loop observe the stop flag. The source now polls
the helper's running state with a bounded wait and ends its iterator when the
helper exits. A real follow-up smoke test exited with code 0 and logged both
`Media native stopped` and `App stopped`.

## Conclusions at the end of the session

- Native Apple voice processing is a viable path for built-in MacBook
  speaker/microphone full duplex.
- The existing WebSocket delegate can retain interruption and truncation
  ownership; adopting AEC does not require adopting WebRTC transport.
- A media mode should have one physical microphone owner. Fan-out should occur
  after capture, not by opening parallel device streams.
- Starting the helper during pre-wake preparation protects activation latency,
  though startup and recovery behavior still need production hardening.
- The processed wake branch appears usable, but responsiveness has not yet been
  measured against the original raw capture with controlled samples.

## Next useful experiments

1. Run the same positive wake samples through the raw 16 kHz path and the
   native processed/resampled path; compare hit rate and detection timing.
2. Add an attempted-phrase protocol or guided live loop so live sensitivity has
   a denominator instead of relying on memory.
3. Measure physical speech onset → server `speech_started` separately from
   server event → playback stop.
4. Decide whether 100 ms native capture frames affect perceived interruption
   latency. Spike direct `AUVoiceIO` only if measurements justify it.
5. Investigate native input/output device selection without losing the
   single-owner invariant or Apple's valid echo-reference route.

## Later update: bounded comparison harness

After this entry's initial session, we added
`lobby-compare-wake-capture --attempts 10`. It performs explicit raw and native
live phases, tests each capture path first, asks the operator to keep or redo
every attempt, evaluates approved audio with the same Sherpa configuration, and
saves both WAV sets plus per-trial JSONL and a summary. This supplies the
attempted-phrase denominator that the exploratory live run lacked.

## 2026-08-03 bounded raw/native result

The first guided comparison completed ten approved attempts per mode in
raw-first order. Results were saved locally under
`recordings/wake-comparison/20260803-224045/`.

| Capture path | Detected | Hit rate | Estimated phrase-end → detection p50 | p95 |
| --- | ---: | ---: | ---: | ---: |
| Raw `sounddevice`, 16 kHz | 10/10 | 100% | 205 ms | 367 ms |
| Native voice-processed, resampled to 16 kHz | 8/10 | 80% | 290 ms | 330 ms |

Native attempts 5 and 7 missed. Their RMS levels were approximately 0.0403 and
0.0422, so neither was among the quietest native recordings. Across all ten
attempts, native mean peak/RMS was 0.400/0.0395 versus raw 0.554/0.0500. Native
capture was lower in level overall, but the per-attempt data does not support
level as a complete explanation for the two misses.

This result establishes a plausible regression, not a final effect size. Ten
attempts per path produce wide uncertainty, the run was raw-first rather than
counterbalanced, and the utterances were comparable but not identical audio.

Code review after the result identified another candidate: the current native
48→16 kHz conversion uses per-chunk linear interpolation. At an exact 3:1
ratio, its sample positions reduce to decimation without an anti-aliasing
low-pass filter. Aliased high-frequency content may reduce recognition quality
or delay decoder finalization. This is a concrete signal-processing flaw worth
fixing before simply tuning Sherpa thresholds or adding gain.

The next controlled sequence is:

1. replace the native downsampler with a stateful anti-aliased 3:1 converter;
2. rerun the bounded comparison in native-first order;
3. compare hit rate and saved-fixture latency with this raw-first baseline;
4. only investigate gain normalization if misses remain and correlate with
   level after proper resampling.

## 2026-08-03 native converter implementation and fixture reuse

The Python linear 48→16 kHz path was removed. The Swift helper now keeps a
persistent `AVAudioConverter` after voice processing and emits a separate 16 kHz
`W` protocol frame for Sherpa. The original 48 kHz `A` frame remains unchanged
for conversation capture, so this change is isolated from the working AEC and
Realtime media path.

To avoid another recording session, the helper also exposes the same converter
as an offline PCM operation. The 32 existing positive recordings were passed
through a 16→48→16 kHz round trip and evaluated against the untouched WAVs:

| Input | Sherpa detections | Estimated latency p50 |
| --- | ---: | ---: |
| Untouched fixtures in the new comparison runner | 27/32 | 320 ms |
| Same fixtures after native converter round trip | 29/32 | 330 ms |

No previously detected fixture regressed. `positive-009-quiet.wav` and
`positive-023-quiet.wav` changed from missed to detected after conversion. The
round trip returned 216 fewer samples over each three-second fixture because of
converter priming/filter delay; the offline evaluator padded the tail back to
the original duration. In the live persistent stream this is a one-time startup
effect rather than a per-chunk loss.

This result shows that the production converter preserves wake-relevant content
on identical recorded speech and does not reproduce the earlier 8/10 live
regression. It cannot prove how fresh speech will behave after Apple's live
voice processing because the original native 48 kHz audio from that run was not
saved. A live repeat is now optional confirmation rather than the only way to
validate the downsampler.

A hardware smoke test then confirmed that the voice-processing helper advertises
48 kHz conversation capture while delivering live 16 kHz wake frames through
the new `W` branch. Six observed wake frames covered approximately 586 ms after
the converter's initial priming, and the helper shut down cleanly.

## 2026-08-03 system-wide voice-processing side effects

During the live converter confirmation, QuickTime playback became noticeably
quieter at the same system volume, and another application's microphone
transcription level also appeared lower. Stopping Wake On immediately restored
QuickTime volume. This isolates the speaker effect to the continuously active
Apple voice-processing I/O session, not `AVAudioConverter`.

The first bounded mitigation keeps AEC and its default-enabled microphone AGC
but configures Apple's other-audio ducking level to `min`, with advanced ducking
disabled. We will compare QuickTime volume before changing AGC or redesigning
the pre-wake audio handoff.

The minimum-ducking live test still reduced QuickTime volume as soon as the
voice-processing helper became active. Stopping Wake On immediately restored
normal playback again. Therefore the available minimum is not equivalent to
zero ducking and does not make continuously active Voice Processing I/O suitable
for an always-listening daemon.

The next design should separate media phases:

```text
LISTENING: ordinary non-voice-processed capture → Sherpa + raw preroll
WAKE ACCEPTED: stop/release ordinary capture → activate native voice processing
CONVERSATION: native AEC capture + native playback
CONVERSATION END: stop voice processing → restore ordinary wake capture
```

The Realtime WebSocket and helper process may still be prepared before wake;
only the device-owning voice-processing engine must remain inactive. Raw wake
preroll should accompany activation so speech immediately following “Hey Lobby”
is not lost during the device handoff. The next measurement is wake acceptance
→ first processed conversation frame and the audible system-volume recovery at
conversation end.

## 2026-08-03 explicit media policy and on-demand AEC implementation

We introduced one backend-neutral `ConversationMediaPolicy` boundary:

| Policy | Behavior |
| --- | --- |
| `raw-full-duplex` | Default; raw capture and interruption, intended for headphones or an already echo-cancelled route |
| `raw-half-duplex` | Raw fallback that suppresses upload during playback and therefore cannot interrupt |
| `native-aec` | Opt-in Apple voice processing only while a conversation is active |

The native helper now reports `mode=raw` and
`voice_processing=false` at preparation. Its 16 kHz `W` frames feed Sherpa as
before. When a wake is accepted, the harness sends its raw bounded preroll to
the delegate first; `V` then asks the helper to enter AEC, and Python gates live
`A` frames until the helper acknowledges `S mode=aec`. Input ownership still
governs the ongoing stream: providing a one-time harness preroll does not turn a
delegate-owned device into harness-owned capture.

The initial implementation tried to return the same stopped `AVAudioEngine`
from voice processing to raw capture. macOS rejected
`setVoiceProcessingEnabled(false)` with Core Audio/AVFAudio error `-10875`.
Releasing and rebuilding the entire graph inside the same process produced the
same result. This is useful negative evidence: on this tested route, the Voice
Processing I/O lifetime is effectively sticky at the helper-process boundary.

The working recovery path cleanly quits the short-lived AEC helper and launches
a fresh raw helper. `NativeMacMedia`, the wake source, the Realtime delegate,
and the overall daemon remain stable. A repeated real-device lifecycle smoke
test completed raw→AEC→raw twice:

| Transition | Observed |
| --- | ---: |
| Raw helper ready | 408 ms on first launch |
| Raw → AEC | 1,371 ms, then 1,312 ms |
| AEC → fresh raw helper | 595 ms, then 687 ms |

The activation cost is significant. Realtime now sends or queues the raw
preroll before starting the synchronous device transition, preserving event
ordering and overlapping server processing with AEC setup. There may still be
an input gap for speech spoken during the Core Audio transition. The next live
trial must verify three things together: idle QuickTime volume is unchanged,
ducking exists only during the active conversation and recovers afterward, and
the post-wake capture gap is acceptable or needs an overlapping handoff design.

## 2026-08-04 live policy acceptance

The full `native-aec` wake and Realtime path passed a user acceptance trial.
Idle playback remained at its normal level, built-in speaker conversation and
interruptions worked, and ending the conversation restored ordinary audio. A
brief audible pause remains during the raw→AEC transition. It is acceptable for
the current phase and is tracked as a later latency optimization rather than a
blocker for starting the computer-use work.

## 2026-08-04 Control Center Voice Isolation trial

We ran a bounded trial of macOS Control Center's Voice Isolation mode while
WakeOn was listening in `native-aec` policy. The Control Center panel identified
the microphone-owning application as **ChatGPT**. This is expected attribution:
the helper was launched by the terminal hosted inside Codex/ChatGPT, and the
same label appears when the user launches the job manually from that terminal.
The user selected Voice Isolation for that active attributed session, so this
is credible evidence that the trial exercised WakeOn under Voice Isolation.

The WakeOn behavior itself was good after the AEC handoff. Laptop-speaker audio
did not cause an observed false interruption, and two intentional barge-ins
stopped playback 0.35 ms and 1.12 ms after the server's
`input_audio_buffer.speech_started` event. The first instruction was cut off,
as expected from the current handoff design. This particular run measured:

| Metric | Observed |
| --- | ---: |
| Wake → first input audio sent | 21.99 ms |
| Raw → AEC transition | 831.03 ms |
| Wake → first assistant playback | 1,914.52 ms |

The assistant's first transcript explicitly reported that the question sounded
cut off. This is direct confirmation that the transition gap is user-visible,
not only a theoretical risk.

The trial was qualitative and did not isolate Voice Isolation from WakeOn's own
AEC, which had already passed speaker rejection and barge-in tests. For a
controlled comparison, the native helper should still expose
`AVCaptureDevice.preferredMicrophoneMode` and `activeMicrophoneMode` in its
readiness/state telemetry, then repeat identical Standard and Voice Isolation
trials. That instrumentation is about measurement confidence, not a reason to
discard this successful run.

## 2026-08-09 retrospective: standalone WebRTC audio processing

The browser WebRTC experiment came before the native Apple AEC implementation.
It established that laptop-speaker full duplex and barge-in were feasible, but
we chose Apple's Voice Processing I/O as the quickest headless native proof.
The resulting implementation is not a custom echo-cancellation algorithm: our
code owns capture, playback, resampling, and lifecycle switching around Apple's
AEC.

A useful alternative is WebRTC's Audio Processing Module (APM) without WebRTC
network transport. The small freedesktop `webrtc-audio-processing` extraction,
or the actively maintained Rust wrapper with a bundled build, can accept:

- assistant playback as the reverse/render reference stream;
- microphone frames as the capture stream; and
- produce echo-cancelled microphone audio for the Realtime connection.

This software-AEC path could keep ordinary microphone capture open continuously,
avoid Apple's system-wide other-audio ducking, and potentially remove the
measured raw-to-Voice-Processing-I/O activation pause. Those are hypotheses to
validate on the built-in MacBook speaker and microphone, not guaranteed outcomes.

The tradeoff is that WakeOn would own the difficult media alignment work. The
render and capture streams need consistent sample rates and 10 ms framing, an
accurate speaker-to-microphone delay estimate, and handling for playback
underruns, audio-device changes, and capture/playback clock drift. Assistant
audio already passes through our playback path, so supplying the render
reference is feasible; reliability and echo rejection still require a bounded
live comparison against the accepted Apple path.

If we revisit the AEC implementation, the preferred first spike is a small Rust
sidecar using [`webrtc-audio-processing`](https://github.com/tonarino/webrtc-audio-processing),
backed by the standalone
[`webrtc-audio-processing` source releases](https://gstreamer.freedesktop.org/src/mirror/webrtc-audio-processing/).
Keep the current Apple implementation as the known-working baseline and compare
ducking, activation latency, barge-in, false speech starts, and repeated echo
rejection before changing the supported media policy.

## 2026-08-13 process-delegate AEC teardown failure

The first combined native-AEC, OpenAI process-delegate, and Peekaboo live run
successfully initialized all three components. AEC entered voice-processing
mode in 887.32 ms, Realtime response audio played through the harness, and a
barge-in stopped playback and sent item truncation. This confirmed the new
cross-process capture/playback route was active.

The daemon stopped when the conversation ended. The AEC helper itself exited
cleanly, but the immediate replacement raw-listening helper failed to acquire
Core Audio with `com.apple.coreaudio.avfaudio error -10875` and exited with
status 2. The process adapter had invoked media teardown from its child-stdout
reader thread; the exception escaped that thread, while the wake source could
also mistake the intentional helper replacement for permanent end-of-stream.

The lifecycle now defers child-triggered media teardown to the harness polling
thread. `NativeMacMedia` marks the AEC-to-raw replacement as a managed restart,
waits briefly for Core Audio device release, and retries transient startup
failures with bounded exponential backoff. `NativeWakeAudioSource` stays open
while that managed restart is in progress. Regression tests cover transient
restart failures, wake capture across a restart longer than the source's queue
timeout, and protocol-thread delivery of the child's `ended` event. The full
suite passes with 130 tests.
