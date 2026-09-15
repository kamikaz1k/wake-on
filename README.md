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
microphone/WAV -> rolling buffer -> sherpa-onnx KWS -> wake route -> delegate
```

See [docs/architecture.md](docs/architecture.md) for component, audio,
connection, delegate, and shutdown lifecycle diagrams.
See the [canonical latency pipeline](docs/latency-pipeline.md) for the current
measurements at a glance. The wake-model decision is recorded in
[ADR 0001](docs/adr/0001-use-chunk-8-wake-model.md), with experiment history in
[the latency notebook](docs/latency.md).
Ongoing investigations and their failed attempts are preserved in the
[engineering notebook](docs/notebook/README.md).
Current priorities are tracked in [TODO.md](TODO.md).

The wake router owns one audio stream:

- `LISTENING`: frames go to sherpa-onnx and a one-second rolling buffer.
- `CONVERSATION`: buffered and live frames go to the agent adapter.
- `ENDING`: microphone upload stops while a graceful farewell finishes.
- When the conversation ends, the detector is reset and listening resumes.

The current CLI installs one immutable route, `hey_lobby → lobby`. The public
API also models a single-daemon route registry so future triggers can select
different supervised delegates without competing microphone listeners. See the
[routed library API](docs/library-api.md).

## Setup

Requirements:

- macOS
- Python 3.11+
- [uv](https://docs.astral.sh/uv/)
- A working microphone for live testing
- An OpenAI API key with Realtime API access

Install dependencies and download Sherpa's English-capable chunk-8 keyword
model:

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

The setup script generates a phone-tokenized Sherpa keyword file from:

```text
HEY LOBBY @HEY_LOBBY
```

Score and threshold are runtime settings, so `--score` and `--threshold`
actually change the decoder rather than being overridden by the keyword file.

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

Realtime turn handoff uses silence-based server VAD by default, with 300 ms of
silence required to end a user turn. Compare it with semantic VAD using:

```sh
uv run lobby-wake --realtime-vad semantic_vad --vad-eagerness high
```

Tune the server-VAD handoff with `--vad-silence-ms`, `--vad-threshold`, and
`--vad-prefix-ms`. Shorter silence values respond faster but can end a turn
during a natural pause.

OpenAI Realtime sessions have a maximum duration of 60 minutes. If a warm
session closes or expires while the app is listening, the app reconnects
automatically.

Useful tuning controls:

```sh
uv run lobby-wake \
  --model-chunk 8 \
  --max-active-paths 16 \
  --trailing-blanks 0 \
  --score 2 \
  --threshold 0.1
```

The low-latency defaults use Sherpa's 160 ms chunk-8 model. Use
`--model-chunk 16` for its 320 ms model when comparing the accuracy/latency
tradeoff.

The default `raw-full-duplex` policy keeps microphone upload active while the
assistant speaks so server VAD can detect an interruption. On
`input_audio_buffer.speech_started`, the WebSocket client immediately stops
queued/current playback and truncates the assistant item to the estimated
amount actually heard. This is the simple path for headphones or an already
echo-cancelled device and does not enable Apple voice processing or system
ducking.

Temporarily fall back to half duplex when using unprocessed laptop speakers:

```sh
uv run lobby-wake --media-policy raw-half-duplex
```

Half duplex prevents speaker feedback, but it also prevents interruption while
the assistant is speaking. For a built-in MacBook speaker and microphone, opt
into conversation-scoped native AEC instead.

### WebRTC laptop AEC spike

Before changing the delegate media path, run the standalone browser spike to
test the MacBook microphone and speakers under WebRTC echo cancellation:

```sh
uv run lobby-webrtc-aec-spike
```

The command starts a loopback-only server, opens the test page, and keeps the
standard OpenAI API key on the Python side. Approve microphone access, then:

1. Run the **echo-only trial** and stay silent while the assistant speaks.
2. Run the **barge-in trial** and interrupt when prompted.

The page shows whether the browser reports echo cancellation, noise
suppression, and automatic gain control as enabled. It also counts likely echo
false starts and estimates server-VAD detection → remote audio silence. Human
readable events appear in the terminal and structured measurements are written
to `webrtc-aec-spike.jsonl`.

Use `--no-open` to start the server without opening a browser. This is
intentionally an acoustic spike rather than a second WakeOn lifecycle: once the
browser path passes the trials, it can become a delegate-owned media
implementation behind the existing contract.

### Native macOS voice-processing spike

The native comparison keeps the existing Realtime WebSocket connection while
moving all microphone capture and conversation playback through Apple's
voice-processing audio path:

```sh
sh scripts/build-native-media-helper.sh
uv run lobby-wake --media-policy native-aec
```

The Swift helper is the single microphone owner in this mode, but it starts in
ordinary raw capture: no Apple voice processing and no other-application
ducking. Its Apple-converted 16 kHz stream feeds Sherpa and the harness retains
the bounded wake preroll. At activation, that raw preroll is sent to the
delegate first, then the helper enters AEC mode and delivers live 48 kHz
conversation capture. Assistant PCM returns through the same AEC graph so it
has the playback reference it needs. At conversation end the AEC helper exits
and is replaced by a fresh raw-listening helper, reliably releasing Core Audio
ducking while the wake harness remains alive.

The media policy is explicit and independent of the conversation backend:

| Policy | Intended route | Interruption | Apple voice processing |
| --- | --- | --- | --- |
| `raw-full-duplex` (default) | Headphones / echo-cancelled device | Yes | Never |
| `raw-half-duplex` | Unprocessed speaker fallback | No during playback | Never |
| `native-aec` | Built-in Mac speaker + microphone | Yes | Active conversation only |

The spike currently uses the system default input and output devices; do not
combine it with `--device`, `--output-device`, or `--audio-file`. See the
[native media protocol and lifecycle](docs/native-media-protocol.md).

Select audio devices or change the response voice:

```sh
uv run lobby-wake --device 1 --output-device 2 --voice marin
```

## Delegate lifecycle

The wake harness targets the backend-neutral `ConversationDelegate` protocol.
Before it begins listening, it calls `prepare()` so a delegate can load local
resources, start a worker, or preconnect a network session. Readiness reports
both whether the delegate can accept a cold activation and whether its warm
path is ready.

On wake, the delegate receives a structured activation containing the wake
event, buffered audio, source sample rate, and a generation-scoped conversation
handle. Delegates may choose harness-streamed microphone audio or declare that
they own their conversation media path—for example, a WebRTC client. The
OpenAI Realtime implementation is the reference delegate, not a dependency of
the wake-word contract. See [the architecture](docs/architecture.md#delegate-contract).

An external long-running backend can be launched with `--agent process`. Wake
On starts it before listening, supervises crashes, and communicates over the
[versioned delegate process protocol](docs/delegate-process-protocol.md):

```sh
uv run lobby-wake \
  --agent process \
  --delegate-command python path/to/delegate.py
```

The command is executed directly without a shell. Put every Wake On option
before `--delegate-command`; remaining arguments belong to the child.

Run the existing OpenAI Realtime reference behind the supervised boundary with:

```sh
uv run lobby-wake \
  --agent process \
  --delegate-command python -m lobby_wake.openai_process_delegate
```

To expose the bounded macOS computer tool to that delegate, grant the process
Screen Recording and Accessibility access, then opt in explicitly:

```sh
uv run lobby-wake \
  --agent process \
  --delegate-command python -m lobby_wake.openai_process_delegate \
  --computer-use \
  --computer-allow-app "Google Chrome" \
  --computer-allow-app ChatGPT
```

When no `--computer-allow-app` option is supplied, the reference delegate keeps
Google Chrome and ChatGPT as its two trial targets. The default computer backend
is macOS Harness. It gives the background planner one `run_macos_harness`
operation and encourages it to batch deterministic Python actions before
re-observing. Chrome webpage work uses the bundled Browser Harness CDP client;
native app and browser-chrome work uses macOS screenshots and accessibility.

To run a Chrome-only trial, narrow the application scope explicitly:

```sh
uv run lobby-wake \
  --agent process \
  --media-policy native-aec \
  --delegate-command python -m lobby_wake.openai_process_delegate \
  --computer-use \
  --computer-allow-app "Google Chrome"
```

The background computer agent executes each generated program in a supervised
macOS Harness child. Printed observations and the last printed PNG path are
returned to the planner as text and a low-detail image. Voice streaming and
barge-in remain independent of these actions. This first integration is
intentionally permissive; hardening the Python, filesystem, shell, and app
boundaries follows only after the end-to-end behavior is validated.

For built-in MacBook speakers and microphone, compose the same process delegate
with harness-owned native AEC. As with all Wake On options, `--media-policy`
must appear before `--delegate-command`:

```sh
sh scripts/build-native-media-helper.sh
uv run lobby-wake \
  --agent process \
  --media-policy native-aec \
  --delegate-command python -m lobby_wake.openai_process_delegate \
  --computer-use \
  --computer-allow-app "Google Chrome" \
  --computer-allow-app ChatGPT
```

The Realtime model receives high-level `use_computer`,
`steer_computer_task`, and `cancel_computer_task` functions. Starting a task
returns its ID immediately; steering revises that same task when the user
changes their mind, while cancellation stops it entirely. The computer worker
currently uses the same `OPENAI_API_KEY` as Realtime but has an independent
Responses context. A background Responses tool loop uses macOS Harness while
microphone streaming, server VAD, and voice turns remain active. Completion
waits behind foreground voice activity before it is spoken. Cancellation stops
the supervised macOS Harness child and suppresses late results. Computer use is
off by default; repeat `--computer-allow-app` to expand its advertised
application scope deliberately. The former Peekaboo backend remains available
for comparison with `--computer-backend peekaboo --peekaboo-command "..."`.

An experimental OAI Sky backend is also available. Sky rejects calls from an
ordinary library process, so Wake On supervises a trusted Codex worker, which
owns the `@oai/sky` session. Start it explicitly:

```sh
uv run lobby-wake \
  --agent process \
  --media-policy native-aec \
  --delegate-command python -m lobby_wake.openai_process_delegate \
  --computer-use \
  --computer-backend sky \
  --computer-allow-app "Google Chrome" \
  --computer-allow-app ChatGPT
```

The Sky worker is asynchronous and can be cancelled or steered while Realtime
voice continues. Steering terminates the active Codex turn and resumes the same
Codex task with the revised goal. Logs record input, cached-input, uncached-input,
and output tokens. Initial experiments found a large Codex context even for a
single Sky call, so macOS Harness remains the default pending live comparison.

Voice handoffs are deliberately terse. The agent gives one short pre-tool
handoff, does not speak again when task acceptance succeeds, and explains only
a rejected or failed acceptance. If an accepted task is still running after ten
seconds, it gives one reassurance and then stays quiet until completion or
failure. Conversation endings are restricted to a quick send-off such as
“Thanks,” “Bye-bye,” or “Have a nice day.”

Computer-agent API usage is accounted separately from Realtime. Each Responses
call logs exact input, cached-input, and output tokens plus request and cumulative
task cost. Logs also include cumulative computer-agent cost for the lifetime of
the delegate process; the JSONL record remains available across restarts for
aggregation. The default computer-task ceiling is **$0.25**. Override it when
starting the process delegate, or pass `0` to disable the hard ceiling:

```sh
python -m lobby_wake.openai_process_delegate \
  --computer-use \
  --computer-max-task-cost-usd 0.10
```

Pricing estimates currently cover the default `gpt-5.4-mini` model at the
standard API rates verified on 2026-08-23. A custom model without a configured
rate still logs exact tokens, but its dollar estimate and hard dollar ceiling
are unavailable.

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
- `agent.playback_interrupted`, including VAD-to-playback-stop latency and the
  estimated heard audio offset
- `agent.item_truncation_sent` and `agent.item_truncation_confirmed`
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

### Record a tuning dataset

Run the guided recorder to test the microphone, record and approve each take,
label quiet/noisy conditions, and collect positive and negative samples:

```sh
uv run lobby-record-samples --positive 30 --negative 30
```

Omit either count to be prompted for it. Approved mono 16 kHz PCM WAV files are
stored under `recordings/` with a `manifest.jsonl`; rejected takes are discarded.
Use `--input-device` or `--output-device` when the system defaults are not the
devices you want.

### Compare raw and native wake capture

Run a bounded guided A/B session when changing the native microphone path:

```sh
uv run lobby-compare-wake-capture --attempts 10
```

The tool runs a microphone test, collects ten approved “Hey Lobby” attempts
through raw `sounddevice` capture, then ten through the native Apple
voice-processed path. Each attempt is evaluated locally with the same Sherpa
configuration and must be kept or redone, so misses remain in the denominator.
It saves both sets of 16 kHz WAV files, `trials.jsonl`, and `summary.json` under
`recordings/wake-comparison/<timestamp>/`. Use `--order native-first` for a
second counterbalanced run.

To verify the native converter without recording more speech, reuse the existing
positive corpus:

```sh
uv run lobby-compare-wake-capture \
  --reuse-recordings recordings/positive \
  --output-dir recordings/wake-converter-check
```

This sends each saved 16 kHz WAV through the production Swift converter as a
16→48→16 kHz round trip and compares Sherpa detections on identical speech. It
tests converter preservation, not the live effect of Apple's voice processing.

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
