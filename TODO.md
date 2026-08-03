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

## Next: explore computer use in the reference delegate

- [ ] **Define the computer-use boundary and safety model.** Keep computer use
  inside the selected conversation delegate rather than the wake core. Specify
  user-visible action feedback, authorization, cancellation, emergency end,
  sensitive-screen handling, and how a long-running task retains its
  generation-scoped conversation capability.
- [ ] **Build one bounded computer-use prototype.** Let Lobby perform a small,
  reversible desktop task while the voice conversation remains interruptible.
  Measure tool startup, action feedback latency, cancellation, and process
  failure behavior before broadening the action surface.

## Follow-up: complete the reference realtime experience

- [ ] **Choose the laptop speaker/microphone echo-cancellation path.** Run a
  bounded spike comparing a WebRTC media client with a native macOS
  `AVAudioEngine` voice-processing adapter. Record measured interruption
  latency, false interruptions from speaker echo, packaging cost, and how each
  option reconnects to the harness lifecycle. See
  [the research note](docs/research/laptop-speaker-barge-in.md).
- [ ] **Implement and validate the chosen AEC path.** Built-in speaker output
  must not trigger VAD; real user speech must interrupt playback reliably. Keep
  wake detection and the harness lifecycle independent of the selected media
  transport.
- [ ] **Measure the full user-turn handoff.** Add a local estimate of the final
  voiced microphone frame so reports include actual-speech-end → server
  `speech_stopped`, then server `speech_stopped` → playback. Compare server VAD
  at 200/300/500 ms and semantic VAD high using live speech. Keep the
  [canonical latency pipeline](docs/latency-pipeline.md) current with the result.

## Later: production hardening

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
