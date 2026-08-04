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
