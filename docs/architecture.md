# Lobby Wake Architecture

Lobby Wake is a macOS-first harness that listens locally for wake triggers,
routes a match to one long-running delegate, and owns that exclusive
conversation until it finishes or is forcibly ended. The current application
configures only **“Hey Lobby”**; the library API preserves the routed daemon
boundary for additional assistants.

Architectural decisions:

- [ADR 0001: Use Sherpa's chunk-8 wake model](adr/0001-use-chunk-8-wake-model.md)

Planned work and research:

- [Engineering notebook](notebook/README.md)
- [Canonical current latency pipeline](latency-pipeline.md)
- [Delegate process protocol](delegate-process-protocol.md)
- [Routed library API](library-api.md)
- [Roadmap](../TODO.md)
- [Laptop speaker/microphone barge-in](research/laptop-speaker-barge-in.md)
- [Native macOS media helper protocol](native-media-protocol.md)
- [Computer-use systems and prototype plan](research/computer-use-systems.md)

## System overview

```mermaid
flowchart LR
    User(("User"))

    subgraph Local["Local macOS process"]
        Source["MicrophoneSource<br/>or WaveFileSource"]
        Ring["AudioRingBuffer<br/>1 second preroll"]
        KWS["SherpaWakeWordEngine<br/>local keyword spotting"]
        Harness["WakeRouter<br/>lifecycle + routing owner"]
        Routes["WakeRoute registry<br/>trigger_id → delegate"]
        Control["ConversationController<br/>serialized end requests"]
        Handle["ConversationHandle<br/>delegate-scoped capability"]
        Contract["ConversationDelegate<br/>backend-neutral contract"]
        Agent["OpenAIRealtimeAgent<br/>reference delegate"]
        Player["AudioPlayer<br/>queued PCM playback"]
        Delegate["Long-running delegate<br/>extension point"]
        Signal["SIGUSR1<br/>emergency end"]
        Logs["EventLogger<br/>terminal + JSONL"]
    end

    subgraph Remote["OpenAI"]
        Realtime["Realtime WebSocket<br/>gpt-realtime-2.1"]
    end

    User -->|"speech"| Source
    Source -->|"float32 frames"| Harness
    Harness --> Ring
    Harness -->|"LISTENING frames"| KWS
    KWS -->|"WakeEvent + trigger_id"| Harness
    Harness --> Routes
    Routes -->|"selected route"| Contract
    Contract --> Agent
    Harness -->|"buffered + live audio"| Agent
    Agent <-->|"24 kHz PCM + events"| Realtime
    Agent --> Player
    Player -->|"assistant speech"| User

    Harness -->|"begin / finish"| Control
    Delegate --> Handle
    Handle -->|"graceful or immediate end"| Control
    Realtime -->|"end_conversation call"| Agent
    Agent -->|"model end request"| Control
    Signal -->|"immediate end"| Harness
    Control -->|"next accepted request"| Harness

    Harness -.-> Logs
    Agent -.-> Logs
    Control -.-> Logs
```

The wake detector and rolling buffer remain local. Audio crosses the network
only after a wake has been accepted.

## Ownership

| Component | Owns | Does not own |
| --- | --- | --- |
| `WakeRouter` | Top-level state, trigger routing, exclusive activation, detector reset | Backend protocol details |
| `WakeRoute` | Immutable trigger ownership and delegate selection | Conversation state |
| `WakeListener` | One-route convenience API over `WakeRouter` | A separate lifecycle implementation |
| `ConversationController` | One active generation and serialized end requests | Audio or delegate execution |
| `ConversationHandle` | A restricted, generation-scoped delegate capability | Harness internals |
| `ConversationDelegate` | Pre-wake preparation, activation, status, audio ownership, and shutdown contract | Any backend protocol |
| `PeekabooTaskRunner` | One interruptible background task, goal revisions, live MCP tool discovery, schema-driven model loop, token/cost budget, cancellation, and task events | Wake routing or Realtime audio |
| `StdioMCPClient` | MCP framing, request correlation, timeouts, and Peekaboo child-process supervision | Tool planning or application-specific behavior |
| `OpenAIRealtimeAgent` | Realtime connection, audio conversion, model events, graceful farewell | Top-level lifecycle state |
| `SherpaWakeWordEngine` | Local wake detection | Conversation audio |
| `AudioPlayer` | Non-blocking assistant playback | Microphone capture |
| `NativeMacMedia` | Optional single-owner processed capture, playback, preroll, and Swift helper supervision | Wake classification or backend protocol |
| `NativeWakeAudioSource` | 16 kHz wake-detector view of continuous native capture | Audio-device ownership or conversation streaming |
| macOS media helper | `AVAudioEngine` voice processing and framed PCM device I/O | API credentials, wake routing, or conversation policy |
| `EventLogger` | Human terminal logs and structured JSONL events | Audio content |

The harness depends on `ConversationDelegate`, not OpenAI Realtime. The current
Realtime class implements that contract in-process, and the supervised adapter
translates the same lifecycle to child-process messages. Routing does not alter
the delegate contract.

Computer use follows the same delegate seam. It is a capability of a selected
delegate, not a responsibility of `WakeRouter`. A voice delegate may bridge a
model tool call to its own background task runner. The current implementation
is intentionally Peekaboo-specific: its live MCP schemas are authoritative and
WakeOn does not redefine Peekaboo actions, application states, or argument
names.

```mermaid
flowchart LR
    A["Realtime voice model"] -->|"use_computer(task, app)"| B["Async delegate bridge"]
    B -->|"immediate accepted(task_id)"| A
    B --> C["PeekabooTaskRunner"]
    C -->|"tools/list schemas"| D["Background Responses tool loop"]
    D -->|"exact tool name + arguments"| C
    C -->|"tools/call"| E["Peekaboo MCP"]
    E -->|"native MCP result"| C
    C -->|"compact text / content descriptor"| D
    C -->|"terminal result"| B
    B -->|"queued system task result when voice is idle"| A
    A -->|"cancel_computer_task(task_id)"| B
    A -->|"steer_computer_task(task_id, new goal)"| B
    F["Voice stop / delegate close"] -->|"generation-scoped cancel"| B
```

The Realtime function call starts the background runner and receives
a task ID immediately, so UI latency does not block microphone streaming,
server VAD, barge-in, or subsequent voice turns. Runner callbacks are drained
through the delegate's poll loop. Intermediate progress remains terminal-only.
A terminal result is inserted as a system conversation item and spoken only
when the user is not speaking, no model response is active, playback is idle,
and a short post-speech grace period has elapsed. Explicit task cancellation
does not end the voice conversation. Conversation generations suppress late
results after stop or reconnect.

The voice layer gives one short handoff before `use_computer`. Successful task
acceptance is recorded silently rather than causing a duplicate acknowledgement;
only rejected or failed acceptance requests an explanatory response. An accepted
task that remains active for ten seconds queues one reassurance behind foreground
voice activity. It does not repeat the reminder, and terminal notification still
uses the normal voice-priority gate.

Google Chrome remains part of Peekaboo rather than becoming a WakeOn browser
Adapter. Peekaboo's `browser` tool description and input schema tell the model
how to use Chrome DevTools; WakeOn forwards the model's selected tool name and
arguments unchanged.

### Computer-task lifecycle

```mermaid
stateDiagram-v2
    [*] --> READY: discover MCP tools
    READY --> RUNNING: start task + generation
    RUNNING --> RUNNING: model tool call → MCP result
    RUNNING --> RUNNING: steer → supersede plan + re-observe
    RUNNING --> COMPLETED: model returns final text
    RUNNING --> FAILED: model / MCP / step limit
    RUNNING --> CANCELLING: matching task cancel
    CANCELLING --> CANCELLED: stop MCP child; suppress late result
    COMPLETED --> RUNNING: next task
    FAILED --> RUNNING: next task
    CANCELLED --> RUNNING: next task
```

The runner owns one task at a time and is independent of the active voice
transport. It converts each discovered MCP definition mechanically into an
OpenAI function definition while preserving the MCP input schema. Model tool
calls go directly to `tools/call`. Results cross a compact model-context
boundary: textual content is bounded, binary content becomes a descriptor, and
raw MCP envelopes and metadata are not accumulated. Native error text returns
to the model so it can recover using Peekaboo's own Interface. A matching cancellation stops
the supervised MCP child and dominates any late result.

Steering retains the task ID and increments its goal revision. Rapid steering
collapses to the newest instruction. A model plan completed after steering is
discarded before it can dispatch a UI action. An MCP action already executing
is allowed to reach its safe boundary; the runner then supplies the revised
goal and requires the subagent to re-observe current state. Changing the target
application requires cancelling and starting a new scoped task.

Each Responses result contributes its exact API-reported input, cached-input,
and output token counts to task-local accounting. Model-specific standard rates
produce request, task, and process-lifetime cumulative USD estimates. The JSONL
event stream provides the persistent source for aggregation across restarts.
Before a request, a conservative
serialized-payload estimate prevents an obviously over-budget call; after a
response, exact usage prevents any plan from acting if the task has crossed its
hard ceiling. The default ceiling is $0.25 per task and is configurable at the
process-delegate boundary. Models without a configured price still report token
usage but cannot enforce a dollar ceiling.

The selected target application is checked before task start and included in
the model instruction. Peekaboo's native `PEEKABOO_ALLOW_TOOLS` configuration
controls which tools appear in `tools/list`; the runner therefore exposes and
describes the same capability it can execute. WakeOn does not currently claim
hard per-tool enforcement beyond Peekaboo's own filtering or hard enforcement
of application identity inside individual tool arguments.

Diagnostics log task IDs, generations, tool names, status, and typed transport
errors. They do not log tool arguments, screen contents, user intent, or raw
MCP results.

## Routed daemon boundary

```mermaid
flowchart LR
    Mic["One microphone stream"] --> Buffer["One preroll buffer"]
    Buffer --> KWS["Multi-keyword detector"]
    KWS -->|"trigger_id"| Router["WakeRouter"]
    Router --> Registry["Immutable WakeRoute registry"]
    Registry --> Lobby["lobby supervisor"]
    Registry --> Timbo["timbo supervisor"]
    Registry --> Jigs["jigs supervisor"]
    Router --> Lease["One active generation lease"]
    Lease -->|"selected route only"| Active["Conversation audio + lifecycle"]
```

The daemon replaces several competing listeners; it does not coordinate
multiple wake daemons. Each trigger has exactly one route owner, and all routes
share one conversation controller. The current CLI creates only the `lobby`
route. Direct delegate-to-delegate handoff is reserved for a future atomic
router operation.

## Delegate contract

The delegate lifecycle deliberately begins before the wake event:

```mermaid
sequenceDiagram
    participant App
    participant Harness as Wake harness
    participant Delegate
    participant Backend

    App->>Harness: prepare()
    Harness->>Delegate: prepare(sample_rate)
    Delegate->>Backend: optional model load / process start / connection
    Note over Harness,Delegate: Wake listening starts immediately<br/>warming may finish asynchronously
    Delegate-->>Harness: status(accepting_activation, warm, health)
    Harness->>Delegate: start(wake, generation handle, audio context)
    alt Harness owns conversation microphone input
        Harness->>Delegate: preroll + live audio frames
    else Delegate owns conversation microphone input
        Delegate->>Delegate: open/capture its media path
    end
    Delegate-->>Harness: active=false when complete
    Harness->>Delegate: close() on application shutdown
```

Contract semantics:

- `prepare(context)` is idempotent and is called before wake listening. A
  delegate may load a local model, start a worker, authenticate, or preconnect a
  socket. Preparation can be asynchronous; `status.warm` reports whether the
  optimized path is ready.
- `status.accepting_activation` is separate from `status.warm`. A delegate can
  accept a wake on a cold path while warming is still in progress. If it is
  false, the harness records the unavailable activation and remains in wake
  listening rather than creating a broken conversation generation.
- `start(context)` receives the wake event, source sample rate, optional
  buffered audio, and a generation-scoped `ConversationHandle`. It must never
  cause a second overlapping activation.
- `AudioInputOwnership.HARNESS` receives the preroll and subsequent frames.
  `DELEGATE` receives no audio from the harness and may own a WebRTC or native
  conversation media path instead.
- Graceful and immediate end requests flow from the harness to
  `request_end`. The scoped handle allows the delegate to request the reverse
  transition without gaining access to orchestrator internals.
- `FAILED` status distinguishes a delegate failure from a normal completion.
  The supervised process adapter restarts failed workers without putting that
  policy into the wake-word core.

## Harness lifecycle

```mermaid
stateDiagram-v2
    [*] --> LISTENING

    state LISTENING {
        [*] --> LocalWakeDetection
        LocalWakeDetection --> LocalWakeDetection: no wake
        LocalWakeDetection --> WakeAccepted: "Hey Lobby"
    }

    LISTENING --> CONVERSATION: WakeEvent.trigger_id<br/>select route<br/>begin generation
    CONVERSATION --> CONVERSATION: stream mic audio<br/>play assistant audio
    CONVERSATION --> ENDING: accepted graceful end
    CONVERSATION --> ENDING: accepted immediate end
    ENDING --> ENDING: wait for farewell playback
    ENDING --> LISTENING: agent inactive<br/>reset detector<br/>clear ring<br/>finish generation

    CONVERSATION --> LISTENING: inactivity or connection failure
    LISTENING --> [*]: application shutdown
```

Important consequences:

- Wake detection runs only in `LISTENING`.
- A second wake cannot create an overlapping conversation.
- Only the active route receives conversation audio.
- Microphone upload stops in `ENDING`.
- An immediate end can collapse `ENDING → LISTENING` in the same audio tick.
- Inactivity and unexpected disconnection may stop the agent directly and
  return the harness to `LISTENING`.

## Wake-to-conversation sequence

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Source as Audio source
    participant Harness as WakeRouter
    participant Routes as WakeRoute registry
    participant Ring as AudioRingBuffer
    participant KWS as Sherpa KWS
    participant Agent as Realtime agent
    participant API as OpenAI Realtime
    participant Player as AudioPlayer

    Note over Agent,API: prepare() may preconnect while LISTENING
    User->>Source: "Hey Lobby..."
    Source->>Harness: audio frame
    Harness->>Ring: append frame
    Harness->>KWS: process frame locally
    KWS-->>Harness: WakeEvent
    Harness->>Routes: resolve trigger_id
    Routes-->>Harness: selected route
    Harness->>Ring: snapshot preroll
    Harness->>Harness: begin conversation generation
    Harness->>Agent: start(context: wake, handle, sample rate, preroll)
    Agent->>API: input_audio_buffer.append
    Harness->>Agent: subsequent live frames
    Agent->>API: stream 24 kHz PCM
    API-->>Agent: speech and response events
    API-->>Agent: response.output_audio.delta
    Agent->>Player: enqueue PCM
    Player-->>User: play assistant response
```

### Warm and cold connection paths

```mermaid
stateDiagram-v2
    [*] --> PRECONNECTING: prepare()
    PRECONNECTING --> WARM: session.updated
    PRECONNECTING --> PRECONNECTING: retry after failure
    WARM --> IN_USE: wake accepted
    IN_USE --> RESETTING: conversation stops
    RESETTING --> PRECONNECTING: wait 500 ms
    WARM --> PRECONNECTING: connection expires or closes
    PRECONNECTING --> IN_USE: cold wake finishes connecting
    IN_USE --> [*]: application shutdown
    WARM --> [*]: application shutdown
```

Preconnection is the default. `--no-preconnect` preserves the cold path for
latency comparisons. Every completed conversation receives a fresh session so
conversation history is not inherited by the next wake.

## WebSocket barge-in lifecycle

```mermaid
sequenceDiagram
    participant Mic as Microphone
    participant Agent as Realtime agent
    participant API as OpenAI Realtime
    participant Player as AudioPlayer

    API-->>Agent: response.output_audio.delta<br/>item_id · content_index
    Agent->>Player: enqueue tagged PCM
    Player-->>Player: track heard PCM offset
    Mic->>API: continuous input_audio_buffer.append
    API-->>Agent: input_audio_buffer.speech_started
    Note over API: active response automatically cancelled
    Agent->>Player: interrupt current + queued playback
    Player-->>Agent: item_id + audio_end_ms
    Agent->>API: conversation.item.truncate
    API-->>Agent: conversation.item.truncated
    Note over Agent,API: late deltas for interrupted item are discarded
```

This lifecycle is enabled by default for headphones and echo-cancelled inputs.
`--media-policy raw-half-duplex` disables microphone upload during playback as
a temporary laptop-speaker fallback; that mode cannot support interruption.
`raw-full-duplex` is the non-processing default, while opt-in `native-aec`
enables Apple voice processing only for an active conversation.

## Unified end-request lifecycle

All termination sources become an `EndConversationRequest`:

```mermaid
flowchart TB
    Model["Realtime model<br/>end_conversation tool"]
    Delegate["Delegate<br/>handle.end()"]
    Kill["Delegate emergency<br/>handle.kill()"]
    Signal["User / operator<br/>SIGUSR1"]
    System["Explicit harness request<br/>system policy"]

    Controller["ConversationController"]
    Request["EndConversationRequest<br/>source · reason · mode · farewell"]
    Harness["Orchestrator"]

    Model --> Controller
    Delegate --> Controller
    Kill --> Controller
    Signal --> Controller
    System --> Controller
    Controller --> Request
    Request --> Harness

    Harness -->|"graceful"| Graceful["ENDING + farewell"]
    Harness -->|"immediate"| Immediate["stop + clear playback"]
    Graceful --> Listening["reset and LISTENING"]
    Immediate --> Listening
```

The controller enforces these rules:

1. Requests are accepted only while a conversation generation is active.
2. Duplicate requests are idempotent.
3. An immediate request can replace a pending graceful request.
4. Delegate handles carry a generation number; a stale delegate cannot end a
   newer conversation.

## Graceful model or delegate ending

```mermaid
sequenceDiagram
    autonumber
    participant Source as Model or delegate
    participant Control as ConversationController
    participant Harness as Orchestrator
    participant Agent as Realtime agent
    participant API as OpenAI Realtime
    participant Player as AudioPlayer

    Source->>Control: request graceful end
    Control-->>Harness: accepted EndConversationRequest
    Harness->>Agent: request_end(request)
    Harness->>Harness: state = ENDING
    Note over Harness,Agent: Live microphone upload stops

    opt End originated as a model tool call
        Agent->>API: function_call_output(status=ending)
    end

    Agent->>API: response.create<br/>tools=[] · tool_choice=none
    API-->>Agent: closing audio deltas
    Agent->>Player: enqueue farewell
    API-->>Agent: response.done<br/>purpose=conversation_close
    Player-->>Agent: playback queue drained
    Agent->>Agent: stop()
    Agent-->>Harness: active = false
    Harness->>Harness: reset detector and ring
    Harness->>Control: finish generation
    Harness->>Harness: state = LISTENING
    Agent->>API: create fresh warm session

    alt Farewell does not finish within 5 seconds
        Agent->>Agent: force stop
    end
```

The final `response.create` clears tools for that response, preventing a
recursive `end_conversation` call. The harness waits for both `response.done`
and the local playback queue to drain before closing.

## Immediate emergency ending

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant CLI
    participant Control as ConversationController
    participant Harness as Orchestrator
    participant Agent as Realtime agent
    participant API as OpenAI Realtime

    Operator->>CLI: kill -USR1 PID
    CLI->>Control: immediate emergency_stop
    Control-->>Harness: accepted request
    Harness->>Agent: request_end(immediate)
    Harness->>Harness: state = ENDING
    Agent->>Agent: clear playback and pending audio
    Agent-xAPI: close WebSocket
    Agent-->>Harness: active = false
    Harness->>Harness: reset and return to LISTENING
    Agent->>API: preconnect fresh session
```

`SIGUSR1` ends only the active conversation. `Ctrl-C` or `SIGTERM` closes the
entire application.

## Audio routing

```mermaid
flowchart LR
    Mic["16 kHz mono float32"]
    Ring["1 second ring"]
    Wake["Sherpa KWS"]
    Convert["Linear resample<br/>float32 → 24 kHz PCM16"]
    API["Realtime WebSocket"]
    Queue["AudioPlayer queue"]
    Speaker["macOS output"]

    Mic --> Ring
    Mic --> Wake
    Ring -->|"on wake"| Convert
    Mic -->|"while CONVERSATION"| Convert
    Convert --> API
    API -->|"base64 PCM deltas"| Queue
    Queue --> Speaker
```

Full duplex is the default so server VAD can hear an interruption. On
`input_audio_buffer.speech_started`, the WebSocket client aborts current and
queued playback, estimates the audio duration heard for the active assistant
item, and sends `conversation.item.truncate`. `raw-half-duplex` is the
half-duplex fallback for unprocessed speaker output. Built-in
speaker/microphone full duplex still requires an AEC media path; see the
[research note](research/laptop-speaker-barge-in.md).

## Key invariants

- There is at most one active conversation generation.
- Audio is never persisted by the harness.
- Wake audio is retained long enough to bridge local detection and remote
  conversation startup.
- Only the harness transitions back to wake listening.
- Delegates receive a restricted capability, not the Realtime socket or
  orchestrator internals.
- Graceful termination is bounded; emergency termination is always available.
- Computer tasks start only for configured applications; Peekaboo's MCP tool
  filter is authoritative for executable tools.
- Accepted computer-task cancellation dominates queued and late results.
- Screen content, screenshots, action parameters, and user intent stay out of
  ordinary lifecycle logs.
- Secrets are loaded from `.env`, excluded from Git, and never included in
  lifecycle logs.

## Implementation map

| Area | File |
| --- | --- |
| Routed lifecycle and public listener API | `src/lobby_wake/orchestrator.py` |
| Delegate lifecycle contract | `src/lobby_wake/agent.py` |
| End requests and delegate capability | `src/lobby_wake/conversation.py` |
| Realtime connection, tools, and audio | `src/lobby_wake/realtime.py` |
| Asynchronous schema-driven Peekaboo tasks | `src/lobby_wake/peekaboo_task.py` |
| Supervised MCP stdio transport | `src/lobby_wake/mcp_stdio.py` |
| Wake detection | `src/lobby_wake/wake.py` |
| Microphone and WAV sources | `src/lobby_wake/audio.py` |
| Rolling preroll buffer | `src/lobby_wake/ring_buffer.py` |
| Speaker playback | `src/lobby_wake/playback.py` |
| Human and JSONL logging | `src/lobby_wake/events.py` |
| CLI assembly and signals | `src/lobby_wake/cli.py` |
