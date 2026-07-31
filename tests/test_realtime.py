from __future__ import annotations

import numpy as np

from lobby_wake.realtime import (
    REALTIME_SAMPLE_RATE,
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
