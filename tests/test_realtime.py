from __future__ import annotations

import base64
import io
import json
import time

import numpy as np

from lobby_wake.agent import DelegateHealth, DelegatePrepareContext, DelegateStartContext
from lobby_wake.conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.playback import PlaybackPosition
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

    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    agent = OpenAIRealtimeAgent(logger, api_key="test-key")
    socket = FakeSocket()
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
