import numpy as np

from lobby_wake.ring_buffer import AudioRingBuffer


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

