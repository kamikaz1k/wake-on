from __future__ import annotations

from lobby_wake import playback
from lobby_wake.playback import AudioPlayer


def test_interrupt_clears_audio_and_returns_heard_position(monkeypatch) -> None:
    class FakeStream:
        latency = 0.1

        def __init__(self) -> None:
            self.abort_count = 0
            self.start_count = 0

        def abort(self) -> None:
            self.abort_count += 1

        def start(self) -> None:
            self.start_count += 1

    player = AudioPlayer(sample_rate=24_000)
    stream = FakeStream()
    player._stream = stream
    player._played_samples[("assistant-item", 0)] = 24_000
    player._latest_key = ("assistant-item", 0)
    player._current_key = ("assistant-item", 0)
    player._current_started_at_ns = 1_000_000_000
    player._current_sample_count = 24_000
    player._playing.set()
    player.enqueue(b"\x00\x00" * 240, item_id="assistant-item", content_index=0)
    monkeypatch.setattr(playback.time, "monotonic_ns", lambda: 1_500_000_000)

    position = player.interrupt("assistant-item", 0)

    assert position is not None
    assert position.item_id == "assistant-item"
    assert position.content_index == 0
    assert position.audio_end_ms == 1400
    assert not player.playing
    assert stream.abort_count == 1
    assert stream.start_count == 1


def test_interrupt_before_playback_returns_zero_position() -> None:
    player = AudioPlayer()
    player.enqueue(b"\x00\x00" * 240, item_id="assistant-item", content_index=0)

    position = player.interrupt("assistant-item", 0)

    assert position is not None
    assert position.audio_end_ms == 0
    assert not player.playing
