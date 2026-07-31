# Lobby Wake

An experimental macOS-first wake-word listener for **“Hey Lobby”**. It keeps
wake detection local with sherpa-onnx, preserves audio spoken immediately after
the wake phrase, and hands the same microphone stream to a conversation-agent
adapter.

The first working vertical slice uses OpenAI Realtime over WebSocket for the
conversation. A deterministic mock remains available for local wake-word
testing without network usage.

## Architecture

```text
microphone/WAV -> rolling buffer -> sherpa-onnx KWS -> orchestrator -> agent
```

See [docs/architecture.md](docs/architecture.md) for component, audio,
connection, delegate, and shutdown lifecycle diagrams.

The orchestrator owns one audio stream:

- `LISTENING`: frames go to sherpa-onnx and a one-second rolling buffer.
- `CONVERSATION`: buffered and live frames go to the agent adapter.
- `ENDING`: microphone upload stops while a graceful farewell finishes.
- When the conversation ends, the detector is reset and listening resumes.

## Setup

Requirements:

- macOS
- Python 3.11+
- [uv](https://docs.astral.sh/uv/)
- A working microphone for live testing
- An OpenAI API key with Realtime API access

Install dependencies and download the English GigaSpeech keyword model:

```sh
uv sync --extra dev
sh scripts/setup-model.sh
cp .env.example .env
```

Set `OPENAI_API_KEY` in `.env`. The file is ignored by Git and is loaded at
startup; the key is never included in lifecycle logs.

The prototype pins sherpa-onnx and its macOS runtime package to the same
version. It also declares sherpa's CLI dependencies explicitly. These declarations
work around incomplete transitive dependency metadata in the current wheels.

The setup script generates a sherpa keyword token file from:

```text
HEY LOBBY :1.5 #0.25
```

The score and threshold are initial tuning values, not production defaults.

## Run

Live microphone:

```sh
uv run lobby-wake
```

Say **“Hey Lobby”**, then continue with your request. The wake detector remains
local. While it listens, the app keeps a configured Realtime session warm. Once
triggered, the one-second preroll and subsequent microphone audio are sent
immediately, and response audio is played through the default macOS output
device. After a conversation ends, the app opens a fresh warm session so the
next interaction does not inherit the previous conversation.

Use a mono, signed 16-bit WAV file:

```sh
uv run lobby-wake --audio-file recordings/hey-lobby.wav
```

Run only the local wake and handoff path:

```sh
uv run lobby-wake --agent mock
```

Disable preconnection to compare cold-start latency:

```sh
uv run lobby-wake --no-preconnect
```

OpenAI Realtime sessions have a maximum duration of 60 minutes. If a warm
session closes or expires while the app is listening, the app reconnects
automatically.

Useful tuning controls:

```sh
uv run lobby-wake --score 1.5 --threshold 0.25 --preroll-seconds 1
```

By default, microphone upload pauses while the assistant is speaking. This
prevents feedback when using laptop speakers, but it also disables barge-in
during playback. With headphones or an echo-cancelled audio device, enable
full-duplex conversation:

```sh
uv run lobby-wake --full-duplex
```

Select audio devices or change the response voice:

```sh
uv run lobby-wake --device 1 --output-device 2 --voice marin
```

## Ending conversations

The Realtime agent can call the harness-owned `end_conversation` function when
the user asks to stop or says goodbye. The harness acknowledges the tool,
requests one tool-free farewell, waits for its audio to finish, and returns to
wake listening. If graceful shutdown takes more than five seconds, it is forced.

A long-running delegate receives a conversation-scoped handle:

```python
handle = orchestrator.conversation_handle
handle.end(reason="task_complete", farewell="All done.")
```

For immediate cancellation:

```python
handle.kill(reason="cancelled")
```

Handles are scoped to the active conversation. A late completion from an old
delegate cannot end a newer conversation.

On macOS and other Unix systems, send `SIGUSR1` to immediately end only the
active conversation while leaving wake listening running:

```sh
kill -USR1 <pid>
```

The application prints its PID at startup. `Ctrl-C` still stops the entire
application.

A lower threshold or higher score makes activation easier and can also increase
false triggers. The int8 model is used by default for lower startup and inference
cost; use `--model-variant fp32` when comparing its accuracy. Lifecycle events
are printed as readable terminal logs while the full structured records are
appended to `latency.jsonl`.

## Latency events

The latency log records:

- `wake.detected`, including the detector-call time
- `wake.speech_tail_estimated`, an in-memory estimate of speech-end-to-wake
  latency
- `activation.listening`, the first visible listening feedback
- `wake.engine_ready`, including model initialization time
- `agent.started`, including `wake_to_agent_start_ms`
- `agent.preconnection_ready`, including warm-session setup time
- `agent.connection_reused`, including time saved at wake
- `agent.connection_ready`, when using a cold connection
- `agent.first_audio_sent`
- `agent.first_response_received`
- `agent.first_response_played`
- response transcripts and conversation lifecycle events
- `agent.stopped`
- orchestration state changes

Summarize one or more logs with percentile distributions:

```sh
uv run lobby-latency-report latency.jsonl
uv run lobby-latency-report latency.jsonl other-run.jsonl
```

The speech-end measurement is an estimate based on 10 ms RMS windows in the
in-memory preroll. It is useful for relative detector tuning, but background
noise can make it less accurate than an annotated audio fixture.

See [the latency baseline and experiment protocol](docs/latency.md) before
changing the runtime or wake-model settings.

## Tests

```sh
uv run pytest
uv run ruff check .
```

## Privacy

Wake detection is entirely local. After activation, buffered and live
conversation audio is sent to OpenAI Realtime. Audio is processed in memory and
is not written to disk. The JSONL log contains timestamps, lifecycle metadata,
and assistant response transcripts, but not audio or API credentials.
