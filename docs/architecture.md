# Lobby Wake Architecture

Lobby Wake is a macOS-first harness that listens locally for **“Hey Lobby”**,
starts one long-running voice delegate, and owns that conversation until it
finishes or is forcibly ended.

Architectural decisions:

- [ADR 0001: Use Sherpa's chunk-8 wake model](adr/0001-use-chunk-8-wake-model.md)

Planned work and research:

- [Roadmap](../TODO.md)
- [Laptop speaker/microphone barge-in](research/laptop-speaker-barge-in.md)

## System overview

```mermaid
flowchart LR
    User(("User"))

    subgraph Local["Local macOS process"]
        Source["MicrophoneSource<br/>or WaveFileSource"]
        Ring["AudioRingBuffer<br/>1 second preroll"]
        KWS["SherpaWakeWordEngine<br/>local keyword spotting"]
        Harness["Orchestrator<br/>lifecycle owner"]
        Control["ConversationController<br/>serialized end requests"]
        Handle["ConversationHandle<br/>delegate-scoped capability"]
        Agent["OpenAIRealtimeAgent<br/>audio and tool adapter"]
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
    KWS -->|"WakeEvent"| Harness
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
| `Orchestrator` | Top-level state, audio routing, detector reset, lifecycle transitions | WebSocket protocol details |
| `ConversationController` | One active generation and serialized end requests | Audio or delegate execution |
| `ConversationHandle` | A restricted, generation-scoped delegate capability | Harness internals |
| `OpenAIRealtimeAgent` | Realtime connection, audio conversion, model events, graceful farewell | Top-level lifecycle state |
| `SherpaWakeWordEngine` | Local wake detection | Conversation audio |
| `AudioPlayer` | Non-blocking assistant playback | Microphone capture |
| `EventLogger` | Human terminal logs and structured JSONL events | Audio content |

The harness exposes the delegate seam through
`orchestrator.conversation_handle`. It does not yet prescribe how the delegate
is spawned; an in-process worker or child-process supervisor can receive the
same restricted handle.

## Harness lifecycle

```mermaid
stateDiagram-v2
    [*] --> LISTENING

    state LISTENING {
        [*] --> LocalWakeDetection
        LocalWakeDetection --> LocalWakeDetection: no wake
        LocalWakeDetection --> WakeAccepted: "Hey Lobby"
    }

    LISTENING --> CONVERSATION: WakeEvent<br/>begin generation<br/>start agent
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
    participant Harness as Orchestrator
    participant Ring as AudioRingBuffer
    participant KWS as Sherpa KWS
    participant Agent as Realtime agent
    participant API as OpenAI Realtime
    participant Player as AudioPlayer

    Note over Agent,API: Session is preconnected while LISTENING
    User->>Source: "Hey Lobby..."
    Source->>Harness: audio frame
    Harness->>Ring: append frame
    Harness->>KWS: process frame locally
    KWS-->>Harness: WakeEvent
    Harness->>Ring: snapshot preroll
    Harness->>Harness: begin conversation generation
    Harness->>Agent: start(preroll, sample rate, wake)
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

Laptop-speaker mode is half-duplex by default: microphone upload pauses while
assistant audio is queued or playing to reduce feedback. `--full-duplex`
continues upload for headphones or an already echo-cancelled audio device, but
correct WebSocket playback cancellation and item truncation are still planned.
Built-in speaker/microphone full duplex also requires an AEC media path; see the
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
- Secrets are loaded from `.env`, excluded from Git, and never included in
  lifecycle logs.

## Implementation map

| Area | File |
| --- | --- |
| Top-level lifecycle and routing | `src/lobby_wake/orchestrator.py` |
| End requests and delegate capability | `src/lobby_wake/conversation.py` |
| Realtime connection, tools, and audio | `src/lobby_wake/realtime.py` |
| Wake detection | `src/lobby_wake/wake.py` |
| Microphone and WAV sources | `src/lobby_wake/audio.py` |
| Rolling preroll buffer | `src/lobby_wake/ring_buffer.py` |
| Speaker playback | `src/lobby_wake/playback.py` |
| Human and JSONL logging | `src/lobby_wake/events.py` |
| CLI assembly and signals | `src/lobby_wake/cli.py` |
