# Lobby Wake

An experimental macOS-first wake-word listener for **“Hey Lobby”**. It keeps
wake detection local with sherpa-onnx, preserves audio spoken immediately after
the wake phrase, and hands the same microphone stream to a conversation-agent
adapter.

The current vertical slice uses a mock conversation agent. Its purpose is to
measure wake detection and handoff behavior before network and model latency are
introduced.

## Architecture

```text
microphone/WAV -> rolling buffer -> sherpa-onnx KWS -> orchestrator -> agent
```

The orchestrator owns one audio stream:

- `LISTENING`: frames go to sherpa-onnx and a one-second rolling buffer.
- `CONVERSATION`: buffered and live frames go to the agent adapter.
- When the conversation ends, the detector is reset and listening resumes.

## Setup

Requirements:

- macOS
- Python 3.11+
- [uv](https://docs.astral.sh/uv/)
- A working microphone for live testing

Install dependencies and download the English GigaSpeech keyword model:

```sh
uv sync --extra dev
sh scripts/setup-model.sh
```

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

Use a mono, signed 16-bit WAV file:

```sh
uv run lobby-wake --audio-file recordings/hey-lobby.wav
```

Useful tuning controls:

```sh
uv run lobby-wake --score 1.5 --threshold 0.25 --preroll-seconds 1
```

A lower threshold or higher score makes activation easier and can also increase
false triggers. The int8 model is used by default for lower startup and inference
cost; use `--model-variant fp32` when comparing its accuracy. Every lifecycle
event is printed as JSON and appended to `latency.jsonl`.

## Latency events

The first slice records:

- `wake.detected`
- `wake.engine_ready`, including model initialization time
- `agent.started`, including `wake_to_agent_start_ms`
- `agent.stopped`
- orchestration state changes

The OpenAI Realtime adapter will extend this with connection-ready,
first-audio-accepted, first-response-received, and first-response-played events.

## Tests

```sh
uv run pytest
uv run ruff check .
```

## Privacy

Microphone audio is processed in memory and is not written to disk. The JSONL
log contains timestamps and lifecycle metadata, not audio.
