from __future__ import annotations

import base64
import io
import json
import time

import numpy as np

from lobby_wake.agent import (
    AudioInputOwnership,
    DelegateHealth,
    DelegatePrepareContext,
    DelegateStartContext,
)
from lobby_wake.conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.peekaboo_task import ComputerToolEvent, ComputerToolResult
from lobby_wake.playback import PlaybackPosition
from lobby_wake.realtime import (
    CANCEL_COMPUTER_TASK_TOOL,
    COMPUTER_SLOW_REASSURANCE_NS,
    DEFAULT_INSTRUCTIONS,
    END_CONVERSATION_TOOL,
    REALTIME_SAMPLE_RATE,
    STEER_COMPUTER_TASK_TOOL,
    USE_COMPUTER_TOOL,
    OpenAIRealtimeAgent,
    build_session_update,
    float_audio_to_pcm16,
    resample_audio,
)


def test_resample_audio_changes_sample_count() -> None:
    samples = np.linspace(-1, 1, 160, dtype=np.float32)

    result = resample_audio(samples, source_rate=16_000, target_rate=REALTIME_SAMPLE_RATE)

    assert result.dtype == np.float32
    assert result.size == 240


def test_float_audio_to_pcm16_clips_and_encodes_little_endian() -> None:
    samples = np.array([-2.0, -1.0, 0.0, 1.0, 2.0], dtype=np.float32)

    raw = float_audio_to_pcm16(samples, source_rate=REALTIME_SAMPLE_RATE)

    decoded = np.frombuffer(raw, dtype="<i2")
    np.testing.assert_array_equal(decoded, [-32767, -32767, 0, 32767, 32767])


def test_session_update_uses_server_vad_by_default() -> None:
    event = build_session_update("gpt-realtime-2.1", "marin", "Be helpful.")
    session = event["session"]

    assert event["type"] == "session.update"
    assert session["type"] == "realtime"
    assert session["output_modalities"] == ["audio"]
    assert session["audio"]["input"]["format"] == {
        "type": "audio/pcm",
        "rate": REALTIME_SAMPLE_RATE,
    }
    assert session["audio"]["input"]["turn_detection"] == {
        "type": "server_vad",
        "threshold": 0.5,
        "prefix_padding_ms": 300,
        "silence_duration_ms": 300,
        "create_response": True,
        "interrupt_response": True,
    }
    assert session["audio"]["output"]["voice"] == "marin"
    assert session["tools"] == [END_CONVERSATION_TOOL]
    assert session["tool_choice"] == "auto"
    assert END_CONVERSATION_TOOL["parameters"]["properties"]["farewell"]["maxLength"] == 40


def test_session_update_exposes_computer_tool_only_when_enabled() -> None:
    event = build_session_update("gpt-realtime-2.1", "marin", "Be helpful.", computer_enabled=True)

    assert event["session"]["tools"] == [
        END_CONVERSATION_TOOL,
        USE_COMPUTER_TOOL,
        STEER_COMPUTER_TASK_TOOL,
        CANCEL_COMPUTER_TASK_TOOL,
    ]


def test_session_update_exposes_enforced_computer_scope() -> None:
    event = build_session_update(
        "gpt-realtime-2.1",
        "marin",
        "Be helpful.",
        computer_enabled=True,
        computer_applications=("TextEdit",),
        computer_tools=("see", "type"),
    )

    tool = event["session"]["tools"][1]
    assert tool["parameters"]["properties"]["application"]["enum"] == ["TextEdit"]
    assert "see, type" in tool["description"]


def test_default_instructions_require_short_casual_goodbyes() -> None:
    assert "Have a nice day" in DEFAULT_INSTRUCTIONS
    assert "do not" in DEFAULT_INSTRUCTIONS.casefold()
    assert "ceremonial sign-off" in DEFAULT_INSTRUCTIONS


def test_session_update_can_use_semantic_vad() -> None:
    event = build_session_update(
        "gpt-realtime-2.1",
        "marin",
        "Be helpful.",
        vad_mode="semantic_vad",
        vad_eagerness="high",
    )

    assert event["session"]["audio"]["input"]["turn_detection"] == {
        "type": "semantic_vad",
        "eagerness": "high",
        "create_response": True,
        "interrupt_response": True,
    }


def test_prepare_starts_preconnection_by_default(monkeypatch) -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    connection_attempts = []
    monkeypatch.setattr(agent._player, "start", lambda: None)
    monkeypatch.setattr(agent, "_ensure_connection", lambda: connection_attempts.append(True))

    assert agent.status.health is DelegateHealth.CREATED
    assert not agent.status.accepting_activation

    agent.prepare(DelegatePrepareContext(sample_rate=16_000))

    assert connection_attempts == [True]
    assert agent.status.accepting_activation
    assert not agent.status.warm
    assert "Agent preconnection started" in stream.getvalue()
    agent.close()
    logger.close()


def test_prepare_can_preserve_cold_start_mode(monkeypatch) -> None:
    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", preconnect=False)
    connection_attempts = []
    monkeypatch.setattr(agent._player, "start", lambda: None)
    monkeypatch.setattr(agent, "_ensure_connection", lambda: connection_attempts.append(True))

    agent.prepare(DelegatePrepareContext(sample_rate=16_000))

    assert connection_attempts == []
    agent.close()
    logger.close()


def test_wake_reuses_ready_connection_without_connecting(monkeypatch) -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []
            self.closed = False

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            self.closed = True

    class Capture:
        def __init__(self, socket: FakeSocket) -> None:
            self.socket = socket
            self.sent_count_at_activation: int | None = None

        def activate_capture(self) -> None:
            self.sent_count_at_activation = len(self.socket.sent)

        def deactivate_capture(self) -> None:
            pass

    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    capture = Capture(socket)
    agent._capture = capture
    connection_attempts = []
    agent._ws = socket
    agent._ready = True
    agent._ready_at_ns = time.monotonic_ns()
    monkeypatch.setattr(agent, "_ensure_connection", lambda: connection_attempts.append(True))

    controller = ConversationController(logger)
    controller.begin()
    agent.start(
        DelegateStartContext(
            wake=WakeEvent("HEY LOBBY", time.monotonic_ns()),
            conversation=controller.handle,
            sample_rate=16_000,
            initial_audio=np.ones(160, dtype=np.float32),
        )
    )

    assert connection_attempts == []
    assert json.loads(socket.sent[0])["type"] == "input_audio_buffer.append"
    assert capture.sent_count_at_activation == 1
    assert "Agent connection reused" in stream.getvalue()
    agent.close()
    logger.close()


def test_delegate_owned_audio_can_start_without_harness_preroll(monkeypatch) -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(
        logger,
        api_key="test-key",
        audio_input=AudioInputOwnership.DELEGATE,
    )
    socket = FakeSocket()
    agent._ws = socket
    agent._ready = True
    agent._ready_at_ns = time.monotonic_ns()
    monkeypatch.setattr(agent, "_ensure_connection", lambda: None)
    controller = ConversationController(logger)
    controller.begin()

    agent.start(
        DelegateStartContext(
            wake=WakeEvent("HEY LOBBY", time.monotonic_ns()),
            conversation=controller.handle,
            sample_rate=16_000,
            initial_audio=None,
        )
    )

    assert agent.capabilities.audio_input is AudioInputOwnership.DELEGATE
    assert socket.sent == []
    agent.close()
    logger.close()


def test_session_update_marks_idle_connection_warm() -> None:
    class FakeSocket:
        def send(self, _message: str) -> None:
            pass

        def close(self) -> None:
            pass

    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    agent._prepared = True
    agent._ws = socket
    agent._connection_started_at_ns = time.monotonic_ns()

    agent._on_message(socket, json.dumps({"type": "session.updated"}))

    assert agent._ready
    assert agent.status.warm
    assert "Agent preconnection ready" in stream.getvalue()
    agent.close()
    logger.close()


def test_stopping_conversation_schedules_fresh_warm_session(monkeypatch) -> None:
    class FakeSocket:
        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    scheduled_reasons = []
    agent._prepared = True
    agent._active = True
    agent._started_at_ns = time.monotonic_ns()
    agent._ws = FakeSocket()
    monkeypatch.setattr(
        agent,
        "_schedule_reconnect",
        lambda *, reason: scheduled_reasons.append(reason),
    )

    agent.stop()

    assert scheduled_reasons == ["session_reset"]
    agent.close()
    logger.close()


def test_model_end_tool_queues_harness_request() -> None:
    class FakeSocket:
        def send(self, _message: str) -> None:
            pass

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    controller = ConversationController(logger)
    controller.begin()
    agent = OpenAIRealtimeAgent(
        logger,
        api_key="test-key",
        conversation_controller=controller,
    )
    socket = FakeSocket()
    agent._ws = socket
    response = {
        "type": "response.done",
        "response": {
            "status": "completed",
            "output": [
                {
                    "type": "function_call",
                    "name": "end_conversation",
                    "call_id": "call-123",
                    "arguments": json.dumps(
                        {
                            "reason": "user_requested",
                            "farewell": "Talk soon.",
                        }
                    ),
                }
            ],
        },
    }

    agent._on_message(socket, json.dumps(response))
    request = controller.take_request()

    assert request is not None
    assert request.source is EndSource.MODEL
    assert request.tool_call_id == "call-123"
    assert request.farewell == "Talk soon."
    agent.close()
    logger.close()


def test_computer_tool_acknowledges_immediately_and_defers_completion_for_voice() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def __init__(self) -> None:
            self.events: list[ComputerToolEvent] = []

        def start(self, task: str, application: str) -> ComputerToolResult:
            assert task == "Type hello"
            assert application == "TextEdit"
            return ComputerToolResult("accepted", "Computer task started.", "task-1")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            events = tuple(self.events)
            self.events.clear()
            return events

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("not_running", "No task.", task_id)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    tool = FakeComputerTool()
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", computer_tool=tool)  # type: ignore[arg-type]
    socket = FakeSocket()
    agent._ws = socket
    agent._active = True
    agent._ready = True
    agent._last_activity_ns = time.monotonic_ns()

    agent._on_message(
        socket,
        json.dumps(
            {
                "type": "response.done",
                "response": {
                    "status": "completed",
                    "output": [
                        {
                            "type": "function_call",
                            "name": "use_computer",
                            "call_id": "call-computer",
                            "arguments": json.dumps(
                                {"task": "Type hello", "application": "TextEdit"}
                            ),
                        }
                    ],
                },
            }
        ),
    )

    events = [json.loads(message) for message in socket.sent]
    assert events[0]["item"]["type"] == "function_call_output"
    assert events[0]["item"]["call_id"] == "call-computer"
    assert json.loads(events[0]["item"]["output"]) == {
        "status": "accepted",
        "summary": "Computer task started.",
        "task_id": "task-1",
    }
    assert len(events) == 1

    tool.events.append(ComputerToolEvent("task-1", 1, "completed", "Hello is visible.", True))
    agent._user_speaking = True
    agent.poll()
    assert len(socket.sent) == 1

    agent._user_speaking = False
    agent._response_active = True
    agent.poll()
    assert len(socket.sent) == 1

    agent._response_active = False
    agent.poll()
    completion_events = [json.loads(message) for message in socket.sent[1:]]
    assert completion_events[0]["item"]["role"] == "system"
    completion = json.loads(completion_events[0]["item"]["content"][0]["text"])
    assert completion == {
        "source": "computer_task",
        "task_id": "task-1",
        "status": "completed",
        "summary": "Hello is visible.",
    }
    assert completion_events[1]["response"]["metadata"] == {
        "purpose": "computer_task_notification",
        "task_id": "task-1",
    }
    agent.close()
    logger.close()


def test_rejected_computer_task_gets_a_spoken_explanation() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def start(self, task: str, application: str) -> ComputerToolResult:
            return ComputerToolResult("denied", "That app is outside the allowed scope.")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            return ()

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("not_running", "No task.", task_id)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(
        logger,
        api_key="test-key",
        computer_tool=FakeComputerTool(),  # type: ignore[arg-type]
    )
    socket = FakeSocket()
    agent._ws = socket
    agent._active = True
    agent._ready = True

    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "use_computer",
                "call_id": "call-denied",
                "arguments": json.dumps(
                    {"task": "Open it", "application": "Messages"}
                ),
            }
        ]
    )

    events = [json.loads(message) for message in socket.sent]
    assert json.loads(events[0]["item"]["output"])["status"] == "denied"
    assert events[1]["response"]["metadata"]["purpose"] == "computer_task_rejected"
    agent.close()
    logger.close()


def test_running_computer_task_reassures_once_after_ten_seconds() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def start(self, task: str, application: str) -> ComputerToolResult:
            return ComputerToolResult("accepted", "Started.", "task-slow")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            return ()

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("not_running", "No task.", task_id)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(
        logger,
        api_key="test-key",
        computer_tool=FakeComputerTool(),  # type: ignore[arg-type]
    )
    socket = FakeSocket()
    agent._ws = socket
    agent._active = True
    agent._ready = True
    agent._last_activity_ns = time.monotonic_ns()
    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "use_computer",
                "call_id": "call-slow",
                "arguments": json.dumps(
                    {"task": "Inspect the page", "application": "Google Chrome"}
                ),
            }
        ]
    )
    assert len(socket.sent) == 1

    agent._computer_task_started_ns["task-slow"] = (
        time.monotonic_ns() - COMPUTER_SLOW_REASSURANCE_NS
    )
    agent.poll()

    events = [json.loads(message) for message in socket.sent[1:]]
    reminder = json.loads(events[0]["item"]["content"][0]["text"])
    assert reminder["status"] == "slow"
    assert events[1]["response"]["metadata"]["purpose"] == "computer_task_notification"
    assert "The task is taking a bit" in events[1]["response"]["instructions"]

    sent_count = len(socket.sent)
    agent._response_active = False
    agent.poll()
    assert len(socket.sent) == sent_count
    agent.close()
    logger.close()


def test_background_computer_task_does_not_block_microphone_upload() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def start(self, task: str, application: str) -> ComputerToolResult:
            return ComputerToolResult("accepted", "Started.", "task-live")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            return ()

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("cancellation_requested", "Stopping.", "task-live")

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(
        logger,
        api_key="test-key",
        computer_tool=FakeComputerTool(),  # type: ignore[arg-type]
    )
    socket = FakeSocket()
    agent._ws = socket
    agent._ready = True
    agent._active = True
    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "use_computer",
                "call_id": "call-live",
                "arguments": json.dumps({"task": "Type hello", "application": "TextEdit"}),
            }
        ]
    )

    agent.send_audio(np.zeros(160, dtype=np.float32), 16_000)

    events = [json.loads(message) for message in socket.sent]
    assert events[-1]["type"] == "input_audio_buffer.append"
    agent.close()
    logger.close()


def test_cancel_computer_tool_does_not_end_voice_conversation() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def __init__(self) -> None:
            self.cancelled: list[tuple[str | None, str]] = []

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            self.cancelled.append((task_id, reason))
            return ComputerToolResult("cancellation_requested", "Stopping.", "task-1")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            return ()

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    tool = FakeComputerTool()
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", computer_tool=tool)  # type: ignore[arg-type]
    socket = FakeSocket()
    agent._ws = socket
    agent._active = True

    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "cancel_computer_task",
                "call_id": "call-cancel",
                "arguments": json.dumps({"task_id": "task-1"}),
            }
        ]
    )

    assert tool.cancelled == [("task-1", "model_requested")]
    assert agent.active
    events = [json.loads(message) for message in socket.sent]
    assert json.loads(events[0]["item"]["output"])["status"] == "cancellation_requested"
    assert events[1]["response"]["metadata"]["purpose"] == "computer_task_cancel"
    agent.close()
    logger.close()


def test_steer_computer_tool_updates_goal_without_ending_voice_conversation() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def __init__(self) -> None:
            self.steered: list[tuple[str | None, str]] = []

        def steer(self, task_id: str | None, instruction: str) -> ComputerToolResult:
            self.steered.append((task_id, instruction))
            return ComputerToolResult("steering_accepted", "Updating.", "task-1")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            return ()

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("not_running", "No task.", task_id)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    tool = FakeComputerTool()
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", computer_tool=tool)  # type: ignore[arg-type]
    socket = FakeSocket()
    agent._ws = socket
    agent._active = True

    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "steer_computer_task",
                "call_id": "call-steer",
                "arguments": json.dumps(
                    {
                        "task_id": "task-1",
                        "instruction": "Do not submit; open the help page instead.",
                    }
                ),
            }
        ]
    )

    assert tool.steered == [
        ("task-1", "Do not submit; open the help page instead.")
    ]
    assert agent.active
    events = [json.loads(message) for message in socket.sent]
    assert json.loads(events[0]["item"]["output"])["status"] == "steering_accepted"
    assert events[1]["response"]["metadata"]["purpose"] == "computer_task_steer"
    agent.close()
    logger.close()


def test_late_computer_result_is_not_announced_in_next_activation() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    class FakeComputerTool:
        def __init__(self) -> None:
            self.events: list[ComputerToolEvent] = []

        def start(self, task: str, application: str) -> ComputerToolResult:
            return ComputerToolResult("accepted", "Started.", "old-task")

        def poll_events(self) -> tuple[ComputerToolEvent, ...]:
            events = tuple(self.events)
            self.events.clear()
            return events

        def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
            return ComputerToolResult("cancellation_requested", "Stopping.", "old-task")

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    tool = FakeComputerTool()
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", computer_tool=tool)  # type: ignore[arg-type]
    old_socket = FakeSocket()
    agent._ws = old_socket
    agent._ready = True
    agent._active = True
    agent._handle_function_calls(
        [
            {
                "type": "function_call",
                "name": "use_computer",
                "call_id": "old-call",
                "arguments": json.dumps({"task": "Type", "application": "TextEdit"}),
            }
        ]
    )
    agent.stop()

    new_socket = FakeSocket()
    agent._ws = new_socket
    agent._ready = True
    agent._active = True
    agent._last_activity_ns = time.monotonic_ns()
    agent._activation_generation += 1
    tool.events.append(ComputerToolEvent("old-task", 1, "completed", "Old task completed.", True))

    agent.poll()

    assert new_socket.sent == []
    agent.close()
    logger.close()


def test_graceful_end_acknowledges_tool_and_requests_tool_free_farewell() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            pass

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    agent._ws = socket
    agent._ready = True
    agent._active = True
    request = EndConversationRequest(
        source=EndSource.MODEL,
        reason="user_requested",
        mode=EndMode.GRACEFUL,
        requested_at_ns=time.monotonic_ns(),
        farewell="Goodbye.",
        tool_call_id="call-123",
    )

    agent.request_end(request)

    events = [json.loads(message) for message in socket.sent]
    assert events[0]["type"] == "conversation.item.create"
    assert events[0]["item"]["call_id"] == "call-123"
    assert events[1]["type"] == "response.create"
    assert events[1]["response"]["tools"] == []
    assert events[1]["response"]["tool_choice"] == "none"
    assert events[1]["response"]["metadata"]["purpose"] == "conversation_close"
    closing = events[1]["response"]["instructions"]
    assert "one quick send-off" in closing
    assert "Bye-bye" in closing
    assert "Do not add any other words" in closing
    agent.close()
    logger.close()


def test_immediate_end_closes_without_farewell() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []
            self.closed = False

        def send(self, message: str) -> None:
            self.sent.append(message)

        def close(self) -> None:
            self.closed = True

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    agent._ws = socket
    agent._ready = True
    agent._active = True

    agent.request_end(
        EndConversationRequest(
            source=EndSource.USER,
            reason="emergency_stop",
            mode=EndMode.IMMEDIATE,
            requested_at_ns=time.monotonic_ns(),
        )
    )

    assert not agent.active
    assert socket.closed
    assert socket.sent == []
    agent.close()
    logger.close()


def test_default_full_duplex_uploads_microphone_audio_during_playback() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

    class FakePlayer:
        playing = True

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    agent._player = FakePlayer()  # type: ignore[assignment]
    agent._ws = socket
    agent._ready = True
    agent._active = True

    agent.send_audio(np.zeros(160, dtype=np.float32), 16_000)

    assert json.loads(socket.sent[0])["type"] == "input_audio_buffer.append"
    logger.close()


def test_half_duplex_fallback_pauses_upload_during_playback() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

    class FakePlayer:
        playing = True

    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", full_duplex=False)
    socket = FakeSocket()
    agent._player = FakePlayer()  # type: ignore[assignment]
    agent._ws = socket
    agent._ready = True
    agent._active = True

    agent.send_audio(np.zeros(160, dtype=np.float32), 16_000)

    assert socket.sent == []
    logger.close()


def test_server_speech_start_stops_playback_and_truncates_item() -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)

    class FakePlayer:
        def __init__(self) -> None:
            self.playing = True
            self.enqueued: list[tuple[bytes, str, int]] = []
            self.interruptions: list[tuple[str | None, int]] = []

        def enqueue(
            self,
            pcm16: bytes,
            _on_start: object,
            *,
            item_id: str,
            content_index: int,
        ) -> None:
            self.enqueued.append((pcm16, item_id, content_index))

        def interrupt(
            self,
            item_id: str | None = None,
            content_index: int = 0,
        ) -> PlaybackPosition:
            self.interruptions.append((item_id, content_index))
            self.playing = False
            assert item_id is not None
            return PlaybackPosition(item_id, content_index, 640)

    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    player = FakePlayer()
    agent._player = player  # type: ignore[assignment]
    agent._ws = socket
    agent._ready = True
    agent._active = True
    agent._on_message(socket, json.dumps({"type": "response.created"}))
    delta = {
        "type": "response.output_audio.delta",
        "item_id": "assistant-item",
        "content_index": 0,
        "delta": base64.b64encode(b"\x00\x00" * 240).decode("ascii"),
    }
    agent._on_message(socket, json.dumps(delta))

    agent._on_message(
        socket,
        json.dumps(
            {
                "type": "input_audio_buffer.speech_started",
                "item_id": "user-item",
                "audio_start_ms": 1200,
            }
        ),
    )

    assert player.interruptions == [("assistant-item", 0)]
    assert json.loads(socket.sent[-1]) == {
        "type": "conversation.item.truncate",
        "item_id": "assistant-item",
        "content_index": 0,
        "audio_end_ms": 640,
    }
    assert "Agent playback interrupted" in stream.getvalue()
    assert "Agent item truncation sent" in stream.getvalue()

    agent._on_message(socket, json.dumps(delta))
    assert len(player.enqueued) == 1
    logger.close()
