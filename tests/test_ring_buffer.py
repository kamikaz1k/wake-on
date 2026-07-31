import numpy as np

from lobby_wake.ring_buffer import AudioRingBuffer, estimate_speech_tail


def test_ring_buffer_keeps_only_requested_duration() -> None:
    buffer = AudioRingBuffer(sample_rate=10, duration_seconds=1)
    buffer.append(np.arange(6, dtype=np.float32))
    buffer.append(np.arange(6, 14, dtype=np.float32))

    np.testing.assert_array_equal(buffer.snapshot(), np.arange(4, 14, dtype=np.float32))
    assert buffer.sample_count == 10


def test_clear_removes_audio() -> None:
    buffer = AudioRingBuffer(sample_rate=10, duration_seconds=1)
    buffer.append(np.ones(5, dtype=np.float32))
    buffer.clear()

    assert buffer.snapshot().size == 0
    assert buffer.sample_count == 0


def test_estimate_speech_tail_measures_trailing_silence() -> None:
    speech = np.full(500, 0.2, dtype=np.float32)
    silence = np.zeros(500, dtype=np.float32)

    estimate = estimate_speech_tail(
        np.concatenate((speech, silence)),
        sample_rate=1000,
        window_ms=10,
    )

    assert estimate is not None
    assert estimate.trailing_silence_ms == 500


def test_estimate_speech_tail_returns_none_for_silence() -> None:
    estimate = estimate_speech_tail(np.zeros(1000, dtype=np.float32), sample_rate=1000)

    assert estimate is None
