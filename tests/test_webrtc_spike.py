from __future__ import annotations

import json
from importlib.resources import files

import pytest

from lobby_wake.webrtc_spike import (
    build_session_config,
    encode_multipart,
    sanitize_telemetry,
)


def test_session_config_enables_server_vad_interruption() -> None:
    config = build_session_config(
        model="gpt-realtime-2.1",
        voice="marin",
        instructions="Be helpful.",
        vad_threshold=0.55,
        vad_prefix_padding_ms=250,
        vad_silence_duration_ms=350,
    )

    assert config["type"] == "realtime"
    assert config["model"] == "gpt-realtime-2.1"
    assert config["audio"]["output"] == {"voice": "marin"}
    assert config["audio"]["input"]["turn_detection"] == {
        "type": "server_vad",
        "threshold": 0.55,
        "prefix_padding_ms": 250,
        "silence_duration_ms": 350,
        "create_response": True,
        "interrupt_response": True,
    }


def test_multipart_contains_sdp_and_session_without_api_key() -> None:
    body, content_type = encode_multipart(
        {"sdp": "v=0\r\nexample", "session": json.dumps({"type": "realtime"})}
    )

    assert content_type.startswith("multipart/form-data; boundary=wake-on-")
    assert b'name="sdp"' in body
    assert b"v=0\r\nexample" in body
    assert b'name="session"' in body
    assert b'"type": "realtime"' in body
    assert b"OPENAI_API_KEY" not in body


def test_telemetry_accepts_only_small_scalar_webrtc_events() -> None:
    event, fields = sanitize_telemetry(
        {
            "event": "webrtc.remote_audio_stopped",
            "fields": {"vad_to_remote_silence_ms": 123.4, "nested": {"secret": "no"}},
        }
    )

    assert event == "webrtc.remote_audio_stopped"
    assert fields == {"vad_to_remote_silence_ms": 123.4}


@pytest.mark.parametrize(
    "payload",
    [
        [],
        {"event": "agent.not_allowed"},
        {"event": "webrtc.ok", "fields": []},
        {"event": "webrtc.ok", "fields": {"bad-key": 1}},
    ],
)
def test_telemetry_rejects_invalid_payloads(payload: object) -> None:
    with pytest.raises(ValueError):
        sanitize_telemetry(payload)


def test_browser_spike_requests_and_reports_echo_cancellation() -> None:
    html = files("lobby_wake").joinpath("webrtc_spike.html").read_text()

    assert "echoCancellation: true" in html
    assert "settings.echoCancellation" in html
    assert "Run echo-only trial" in html
    assert "Run barge-in trial" in html
    assert "webrtc.remote_audio_stopped" in html
    assert "trial = null" in html
    assert "webrtc.trial_completed" in html
