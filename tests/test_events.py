from __future__ import annotations

import io
import json

from lobby_wake.events import EventLogger, WakeEvent


def test_wake_event_derives_stable_trigger_id() -> None:
    event = WakeEvent("Hey, Lobby!", 123)

    assert event.trigger_id == "hey_lobby"


def test_wake_event_normalizes_explicit_decoder_label() -> None:
    event = WakeEvent("Hey Lobby", 123, trigger_id="HEY_LOBBY")

    assert event.trigger_id == "hey_lobby"


def test_console_output_is_human_readable() -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)

    logger.emit("wake.detected", phrase="HEY LOBBY", buffered_audio_ms=1000.0)
    logger.close()

    line = stream.getvalue()
    assert "INFO  Wake detected" in line
    assert 'phrase="HEY LOBBY"' in line
    assert "buffered audio=1000.00 ms" in line
    assert '{"event":' not in line


def test_file_output_remains_structured_jsonl(tmp_path) -> None:
    output = tmp_path / "latency.jsonl"
    logger = EventLogger(output, stream=io.StringIO())

    logger.emit("agent.connection_ready", connection_ms=123.45)
    logger.close()

    record = json.loads(output.read_text(encoding="utf-8"))
    assert record["event"] == "agent.connection_ready"
    assert record["connection_ms"] == 123.45
    assert isinstance(record["monotonic_ns"], int)
    assert isinstance(record["wall_time"], float)


def test_error_events_use_error_level() -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)

    logger.emit("agent.api_error", detail="bad request")
    logger.close()

    assert "ERROR Agent api error" in stream.getvalue()
