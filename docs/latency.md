# Latency baseline

The accepted model-selection decision and complete experiment rationale are in
[ADR 0001: Use Sherpa's chunk-8 wake model](adr/0001-use-chunk-8-wake-model.md).

Lobby Wake records timestamps at each boundary so perceived activation delay
can be attributed to the wake detector, local harness, network connection,
Realtime speech detection, model response, or playback.

## Activation path

```mermaid
flowchart LR
    Speech["Wake phrase ends"]
    Wake["Sherpa emits wake"]
    Feedback["Listening feedback logged"]
    Start["Agent starts"]
    Connection["Realtime connection ready"]
    Upload["First audio sent"]
    Server["Server detects speech"]
    Response["First response audio received"]
    Playback["First response audio played"]

    Speech -->|"estimated locally"| Wake
    Wake --> Feedback
    Wake --> Start
    Start --> Connection
    Connection --> Upload
    Upload --> Server
    Server --> Response
    Response --> Playback
```

The event log contains monotonic timestamps and explicit duration fields. Build
a percentile report from one or more runs with:

```sh
uv run lobby-latency-report latency.jsonl
```

## Initial measurements

These numbers establish direction, not a performance guarantee. Historical
values combine a small number of development runs. The phrase-end measurement
comes from one repeatable WAV fixture and uses an in-memory RMS estimate.

| Stage | Initial result | Interpretation |
| --- | ---: | --- |
| Estimated phrase end → wake | 545 ms | Largest local activation gap |
| Wake → listening feedback | 0.54 ms | Harness feedback is effectively immediate |
| Wake → warm connection | 1.08 ms p50 | Preconnection removes startup cost |
| Wake → cold connection | 104 ms in latest run; 900 ms historical p50 | Avoid the cold path |
| Wake → first audio upload | 106 ms on cold run | Dominated by connection readiness |
| Speech stop → first response audio | 586 ms on latest run; 576 ms historical p50 | Remote response path |
| Response received → playback | 0.92 ms on latest run; 0.40 ms historical p50 | Local playback handoff is negligible |

## Realtime turn handoff

The original integration explicitly used semantic VAD with high eagerness.
Historical logs measured approximately 576 ms p50 and 694 ms p95 from the
server's `input_audio_buffer.speech_stopped` event to first response audio. They
did not measure how long semantic VAD waited between the user's actual final
word and that event.

Server VAD is now the trial default for a more deterministic handoff:
[OpenAI's VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad)
defines `silence_duration_ms` as the silence required to detect speech stop and
notes that shorter values detect turns faster.

| Setting | Default |
| --- | ---: |
| Mode | `server_vad` |
| Silence duration | 300 ms |
| Activation threshold | 0.5 |
| Prefix padding | 300 ms |

The accepted Realtime session configuration and speech events include the VAD
mode in structured logs. Compare the previous behavior with:

```sh
uv run lobby-wake --realtime-vad semantic_vad --vad-eagerness high
```

Shorter `--vad-silence-ms` values can reduce handoff time but increase the risk
of ending a turn during a natural pause. This should be evaluated by speaking,
pausing mid-sentence, and recording both perceived interruption and the existing
speech-stop-to-playback metric.

Audio callback blocks of 20, 40, and 80 ms all emitted the wake at approximately
the same point in the fixture: 547, 545, and 551 ms after estimated phrase end.
Callback size is therefore not the first tuning target.

## Wake-model latency investigation

The original GigaSpeech model is exported with `chunk_size=16`. [Sherpa's model
documentation](https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html)
identifies chunk-16 as 320 ms streaming latency and chunk-8 as 160 ms. Trigger
timestamps from the local recordings followed the same 320 ms inference cadence,
confirming that Python's audio callback size was not responsible for the delay.

Sherpa's newer English-capable model includes a `chunk_size=8` export documented
at 160 ms model latency. On the same 32 approved positive recordings:

| Configuration | Detected | Estimated phrase-end → wake p50 | p95 |
| --- | ---: | ---: | ---: |
| Original GigaSpeech chunk-16 defaults | 13/32 | 530 ms | 760 ms |
| New chunk-8 low-latency defaults | 29/32 | 320 ms | 504 ms |

The default low-latency profile is chunk-8 int8 inference, 16 active paths, zero
trailing blanks, score `2.0`, and threshold `0.1`. A single fixture improved from
approximately 545 ms to 343 ms. These phrase-end values use the RMS estimator,
so the relative result is more reliable than the absolute number, particularly
for recordings containing continuous background noise.

The chunk-8 model recovers about 200 ms at p50 while keeping inference comfortably
faster than real time on the development Mac. The remaining delay is primarily
model finalization and the 160 ms chunk cadence, not Python orchestration.

## Measurement protocol

For a useful distribution:

1. Keep the model, keyword file, score, threshold, trailing blanks, hardware,
   room, and microphone position fixed.
2. Capture at least 30 successful activations plus negative/background samples.
3. Run the same fixture or phrase set for each candidate configuration.
4. Compare p50 and p95 activation latency together with false accepts and false
   rejects. Latency alone is not a safe wake-model objective.
5. Separate warm and cold Realtime connection results.

The phrase-end estimator analyzes 10 ms RMS windows in the one-second preroll
buffer and retains no audio. It is suitable for relative tuning. An annotated
fixture is more trustworthy when background noise is close to speech volume.

## Native implementation decision

Do not rewrite the harness in Swift or C++ for latency yet. Sherpa's Python
package already invokes its native inference engine, and measured Python
orchestration after wake is about 1–2 ms. A native macOS layer may still be
worthwhile later for distribution, launch-at-login integration, audio-session
control, power usage, and UI feedback, but it cannot recover time spent inside
the wake model's inference cadence and finalization.

Sherpa's `num_trailing_blanks` is exposed through `--trailing-blanks`. On the
chunk-8 model, reducing it from `1` to `0` recovered roughly 10–30 ms without
reducing detections in the positive set, so the low-latency profile uses `0`.

The next core latency boundary is model choice: a wake model with a shorter
inference cadence or a phrase-specific classifier. Negative audio is needed
before declaring the more sensitive decoder settings production-safe, but it
is not required to continue measuring activation latency.
