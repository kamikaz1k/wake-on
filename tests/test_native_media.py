from __future__ import annotations

import io
import struct
import sys
import threading
import time
from pathlib import Path

import numpy as np

from lobby_wake.events import EventLogger
from lobby_wake.native_media import (
    NativeMacMedia,
    NativeWakeAudioSource,
    encode_media_frame,
    read_media_frame,
)


def test_media_protocol_round_trip() -> None:
    stream = io.BytesIO(encode_media_frame(b"A", b"pcm"))

    assert read_media_frame(stream) == (b"A", b"pcm")


def test_media_protocol_rejects_invalid_type() -> None:
    try:
        encode_media_frame(b"AB")
    except ValueError as error:
        assert "one byte" in str(error)
    else:
        raise AssertionError("invalid frame type was accepted")


def test_native_media_bridge_captures_and_completes_playback() -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    helper = Path(__file__).parent / "fixtures" / "native_media_helper.py"
    media = NativeMacMedia(logger, (sys.executable, helper))
    captured: list[tuple[np.ndarray, int]] = []
    captured_event = threading.Event()
    playback_started = threading.Event()

    def on_capture(samples: np.ndarray, sample_rate: int) -> None:
        captured.append((samples, sample_rate))
        captured_event.set()

    media.set_capture_handler(on_capture)
    media.start()
    assert not captured_event.is_set()
    media.activate_capture()
    assert captured_event.wait(1)
    media.enqueue(
        struct.pack("<hh", 100, -100),
        playback_started.set,
        item_id="item-1",
    )
    deadline = time.monotonic() + 1
    while media.playing and time.monotonic() < deadline:
        time.sleep(0.01)

    assert playback_started.is_set()
    assert not media.playing
    assert captured[0][1] == 48_000
    np.testing.assert_allclose(captured[0][0], [-1.0, 0.0, 32767 / 32768])
    assert "Media native ready" in stream.getvalue()
    assert "Media native aec active" in stream.getvalue()

    media.deactivate_capture()
    assert "Media native raw active" in stream.getvalue()

    media.close()
    logger.close()


def test_native_media_starts_raw_and_only_delivers_conversation_capture_in_aec() -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    helper = Path(__file__).parent / "fixtures" / "native_media_helper.py"
    media = NativeMacMedia(logger, (sys.executable, helper))
    captured: list[np.ndarray] = []
    media.set_capture_handler(lambda samples, _rate: captured.append(samples))

    media.start()
    time.sleep(0.05)
    assert captured == []
    assert "media mode=\"raw\"" in stream.getvalue().lower()
    assert "voice processing=false" in stream.getvalue().lower()

    media.activate_capture()
    deadline = time.monotonic() + 1
    while not captured and time.monotonic() < deadline:
        time.sleep(0.01)
    assert captured

    media.deactivate_capture()
    media.close()
    logger.close()


def test_native_wake_source_uses_continuous_helper_capture() -> None:
    logger = EventLogger(stream=io.StringIO())
    helper = Path(__file__).parent / "fixtures" / "native_media_helper.py"
    media = NativeMacMedia(logger, (sys.executable, helper))
    source = NativeWakeAudioSource(media)

    media.start()
    samples = next(source.frames())

    assert source.sample_rate == 16_000
    np.testing.assert_allclose(samples, [-1.0])

    source.close()
    media.close()
    logger.close()


def test_native_wake_source_stops_when_helper_exits() -> None:
    logger = EventLogger(stream=io.StringIO())
    helper = Path(__file__).parent / "fixtures" / "native_media_helper.py"
    media = NativeMacMedia(logger, (sys.executable, helper))
    source = NativeWakeAudioSource(media)
    frames = source.frames()

    media.start()
    next(frames)
    media.close()

    try:
        next(frames)
    except StopIteration:
        pass
    else:
        raise AssertionError("wake source remained blocked after helper exit")

    source.close()
    logger.close()
