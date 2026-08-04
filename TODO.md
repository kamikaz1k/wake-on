# Lobby Wake roadmap

This is the canonical prioritized work list. Architecture rationale and measured
results belong in `docs/`; this file tracks what remains.

## Now: finish the delegate/library boundary

- [x] **Implement correct WebSocket barge-in for echo-cancelled inputs.**
  Continue microphone upload during assistant playback; track the active
  assistant item and played audio offset; on
  `input_audio_buffer.speech_started`, immediately stop local playback and send
  `conversation.item.truncate`; log detection-to-playback-stop latency. This is
  required for headphones and for any future AEC input path.
- [x] **Define the in-process delegate contract.** The backend-neutral contract
  now includes idempotent pre-wake preparation, readiness/warm status, a
  conversation-scoped start payload and end handle, declared microphone
  ownership, graceful end, emergency end, and failure health. The OpenAI
  Realtime implementation remains an in-process reference delegate.
- [x] **Add a supervised delegate adapter.** The harness can launch and monitor
  an external long-running process through a versioned JSONL protocol. It
  supports pre-wake warming, explicit health, streamed or delegate-owned audio,
  generation-scoped end requests, bounded graceful end, emergency termination,
  and crash recovery without exposing shell execution or secrets in logs.
- [x] **Extract a stable routed library API.** `WakeListener` provides the
  current one-agent embedding, while `WakeRouter`, immutable `WakeRoute`s, and
  stable trigger IDs preserve a single-daemon multiplexer boundary. The CLI
  intentionally configures only the `lobby` route in this phase. Atomic
  delegate handoff and multi-route configuration remain later extensions.
- [x] **Add an explicit conversation-media policy boundary.** The default
  `raw-full-duplex` path never enables Apple voice processing; callers can opt
  into `raw-half-duplex` or conversation-scoped `native-aec`. Delegate-owned
  capture may receive the one-time harness preroll, and native AEC returns to a
  fresh raw helper after every conversation so system ducking is released.

## Next: explore computer use in the reference delegate

- [x] **Survey computer-use systems and define the spike.** Keep computer use
  inside the selected conversation delegate rather than the wake core. The
  initial recommendation is an OpenAI Realtime function bridge to a separate,
  provider-neutral worker, with Peekaboo as the first macOS executor candidate
  and Cua as the isolation/evaluation alternative. See the
  [research note](docs/research/computer-use-systems.md).
- [ ] **Define and test the computer-task contract.** Add a fake worker before
  touching the desktop. Cover start, progress, approval, generation-scoped
  cancellation, stale observations, late results, failure, and emergency end.
- [ ] **Run the bounded executor bake-off.** Compare pinned versions of Peekaboo
  and Cua's local macOS driver on the reversible TextEdit fixture. Measure warm
  and cold startup, first visible progress, action latency, 20-run reliability,
  cancellation latency, permissions, and packaging weight.
- [ ] **Bridge the winning executor into Lobby.** Add one Realtime function tool
  to the reference delegate, keep voice interruption active during the task,
  and return progress and completion without leaking the computer-use protocol
  into WakeOn's delegate contract.
- [ ] **Validate the safety model.** Enforce app/action allowlists, action-time
  approval, untrusted on-screen content handling, sensitive-data redaction, and
  dominant cancellation before broadening the action surface.

## Follow-up: complete the reference realtime experience

- [ ] **Choose the laptop speaker/microphone echo-cancellation path.** Run a
  bounded spike comparing a WebRTC media client with a native macOS
  `AVAudioEngine` voice-processing adapter. Record measured interruption
  latency, false interruptions from speaker echo, packaging cost, and how each
  option reconnects to the harness lifecycle. The WebRTC spike passed a clean
  silent echo-only rerun and measured about 90 ms from remote speech detection
  to audio silence during barge-in. A native `AVAudioEngine` helper, framed PCM
  bridge, processed preroll, and Realtime integration are implemented. A live
  trial passed built-in speaker playback and interruption, with successful
  activations reaching first audio in about 775–909 ms. The duplicate capture
  regression found during that trial has been replaced with one native stream
  feeding both wake detection and conversation media. A repeat trial detected
  five distinct activations. A guided raw/native comparison runner now records
  approved attempts, misses, audio fixtures, and summary metrics. Its first
  raw-first run measured 10/10 raw versus 8/10 native. The unfiltered Python
  downsampler has been replaced by a persistent Apple converter. On the same 32
  existing fixtures, a 16→48→16 round trip preserved every prior detection and
  improved the comparison runner from 27/32 to 29/32; a live native-first repeat
  is optional confirmation. See
  [the research note](docs/research/laptop-speaker-barge-in.md).
- [x] **Validate the chosen AEC path and lifecycle.** Built-in speaker output
  must not trigger VAD; real user speech must interrupt playback reliably. Keep
  wake detection and the harness lifecycle independent of the selected media
  transport. Continuously active Apple Voice Processing I/O was rejected
  because even minimum ducking lowered other applications' playback. Use raw
  capture while listening and hand device ownership to native AEC only for the
  active conversation, preserving raw preroll across the transition. The
  policy and raw→AEC→raw lifecycle are implemented. A repeated hardware smoke
  measured roughly 1.31–1.37 s to enter AEC and 0.60–0.69 s to restore a fresh
  raw helper. The 2026-08-04 full wake/Realtime trial confirmed speaker playback,
  interruption, idle volume, and ducking recovery. The brief transition pause
  is acceptable for this phase.
- [ ] **Measure the full user-turn handoff.** Add a local estimate of the final
  voiced microphone frame so reports include actual-speech-end → server
  `speech_stopped`, then server `speech_stopped` → playback. Compare server VAD
  at 200/300/500 ms and semantic VAD high using live speech. Keep the
  [canonical latency pipeline](docs/latency-pipeline.md) current with the result.

## Later: production hardening

- [ ] Reduce or mask the roughly 1.3-second raw→AEC transition pause without
  reintroducing continuous system ducking or multiple competing microphone owners.
- [ ] Evaluate a shorter-cadence or phrase-specific “Hey Lobby” model against
  the chunk-8 baseline if another ~100–300 ms of wake latency is necessary.
- [ ] Record and evaluate representative negative audio before treating the
  permissive wake score/threshold as production-safe.
- [ ] Add macOS service packaging: microphone permission UX, launch at login,
  process supervision, status/activation feedback, and clean upgrades.
- [ ] Add long-running soak tests covering Realtime reconnection, expired warm
  sessions, repeated conversations, delegate crashes, and audio-device changes.
- [ ] Define the portability boundary for future non-macOS audio backends.

## Completed foundations

- [x] Local Sherpa wake detection for “Hey Lobby”.
- [x] Chunk-8 wake model and latency instrumentation.
- [x] Realtime voice conversation with preconnection and PCM playback.
- [x] Readable terminal logs plus structured latency events.
- [x] Harness-owned graceful and emergency conversation ending.
- [x] Configurable server/semantic Realtime VAD.
- [x] Headphone/echo-cancelled WebSocket barge-in with playback truncation.
- [x] Guided positive/negative sample recorder.
- [x] Architecture, lifecycle, latency, and wake-model decision documentation.
