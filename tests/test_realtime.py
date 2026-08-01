from __future__ import annotations

import io
import json
import time

import numpy as np

from lobby_wake.conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.realtime import (
    END_CONVERSATION_TOOL,
    REALTIME_SAMPLE_RATE,
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

    agent.prepare()

    assert connection_attempts == [True]
    assert "Agent preconnection started" in stream.getvalue()
    agent.close()
    logger.close()


def test_prepare_can_preserve_cold_start_mode(monkeypatch) -> None:
    logger = EventLogger(stream=io.StringIO())
    agent = OpenAIRealtimeAgent(logger, api_key="test-key", preconnect=False)
    connection_attempts = []
    monkeypatch.setattr(agent._player, "start", lambda: None)
    monkeypatch.setattr(agent, "_ensure_connection", lambda: connection_attempts.append(True))

    agent.prepare()

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

    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
    connection_attempts = []
    agent._ws = socket
    agent._ready = True
    agent._ready_at_ns = time.monotonic_ns()
    monkeypatch.setattr(agent, "_ensure_connection", lambda: connection_attempts.append(True))

    agent.start(
        np.ones(160, dtype=np.float32),
        16_000,
        WakeEvent("HEY LOBBY", time.monotonic_ns()),
    )

    assert connection_attempts == []
    assert json.loads(socket.sent[0])["type"] == "input_audio_buffer.append"
    assert "Agent connection reused" in stream.getvalue()
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
    agent._ws = socket
    agent._connection_started_at_ns = time.monotonic_ns()

    agent._on_message(socket, json.dumps({"type": "session.updated"}))

    assert agent._ready
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
