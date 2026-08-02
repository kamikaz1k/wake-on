# Lobby Wake roadmap

This is the canonical prioritized work list. Architecture rationale and measured
results belong in `docs/`; this file tracks what remains.

## Now: complete realtime conversation behavior

- [x] **Implement correct WebSocket barge-in for echo-cancelled inputs.**
  Continue microphone upload during assistant playback; track the active
  assistant item and played audio offset; on
  `input_audio_buffer.speech_started`, immediately stop local playback and send
  `conversation.item.truncate`; log detection-to-playback-stop latency. This is
  required for headphones and for any future AEC input path.
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

## Next: finish the delegate/library boundary

- [ ] **Define the delegate process contract.** Specify start payload, streamed
  audio ownership, health/ready events, graceful end, emergency kill, crash
  recovery, and generation-scoped authorization.
- [ ] **Add a supervised delegate adapter.** Allow the wake harness to launch
  and monitor an external long-running process rather than coupling the product
  to `OpenAIRealtimeAgent` in-process.
- [ ] **Extract a stable library API.** Separate reusable wake/listen lifecycle
  components from the current CLI assembly so another macOS application can
  embed the harness and select its own delegate.

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
