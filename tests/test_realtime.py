from __future__ import annotations

import io
import json
import time

import numpy as np

from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.realtime import (
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


def test_session_update_uses_realtime_audio_schema() -> None:
    event = build_session_update("gpt-realtime-2.1", "marin", "Be helpful.")
    session = event["session"]

    assert event["type"] == "session.update"
    assert session["type"] == "realtime"
    assert session["output_modalities"] == ["audio"]
    assert session["audio"]["input"]["format"] == {
        "type": "audio/pcm",
        "rate": REALTIME_SAMPLE_RATE,
    }
    assert session["audio"]["input"]["turn_detection"]["type"] == "semantic_vad"
    assert session["audio"]["output"]["voice"] == "marin"


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
