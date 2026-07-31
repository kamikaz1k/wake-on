from __future__ import annotations

import queue
import time
import wave
from collections.abc import Iterator
from pathlib import Path
from typing import Protocol

import numpy as np

from .ring_buffer import FloatAudio


class AudioSource(Protocol):
    sample_rate: int

    def frames(self) -> Iterator[FloatAudio]: ...

    def close(self) -> None: ...


class MicrophoneSource:
    """Captures one mono float32 stream. Importing sounddevice is intentionally lazy."""

    def __init__(
        self,
        sample_rate: int = 16_000,
        block_duration_ms: int = 80,
        device: int | str | None = None,
    ) -> None:
        if block_duration_ms <= 0:
            raise ValueError("block_duration_ms must be positive")
        self.sample_rate = sample_rate
        self._block_size = round(sample_rate * block_duration_ms / 1000)
        self._device = device
        self._queue: queue.Queue[FloatAudio | BaseException] = queue.Queue(maxsize=32)
        self._stream = None

    def frames(self) -> Iterator[FloatAudio]:
        import sounddevice as sd

        def callback(indata: np.ndarray, _frames: int, _time: object, status: object) -> None:
            if status:
                print(f"audio_status={status}", flush=True)
            chunk = np.asarray(indata[:, 0], dtype=np.float32).copy()
            try:
                self._queue.put_nowait(chunk)
            except queue.Full:
                # Latency matters more than retaining stale microphone frames.
                try:
                    self._queue.get_nowait()
                    self._queue.put_nowait(chunk)
                except queue.Empty:
                    pass

        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            blocksize=self._block_size,
            device=self._device,
            channels=1,
            dtype="float32",
            callback=callback,
        )
        self._stream.start()
        while True:
            item = self._queue.get()
            if isinstance(item, BaseException):
                raise item
            yield item

    def close(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None


class WaveFileSource:
    """Streams a mono, 16-bit WAV file in realtime-sized chunks."""

    def __init__(
        self,
        path: Path,
        block_duration_ms: int = 80,
        *,
        pace_realtime: bool = False,
    ) -> None:
        # The source owns this long-lived handle and releases it in close().
        self._wave = wave.open(str(path), "rb")  # noqa: SIM115
        if self._wave.getnchannels() != 1:
            raise ValueError("WAV input must be mono")
        if self._wave.getsampwidth() != 2:
            raise ValueError("WAV input must use signed 16-bit samples")
        self.sample_rate = self._wave.getframerate()
        self._block_size = round(self.sample_rate * block_duration_ms / 1000)
        self._pace_realtime = pace_realtime

    def frames(self) -> Iterator[FloatAudio]:
        next_frame_at = time.monotonic()
        while raw := self._wave.readframes(self._block_size):
            yield np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            if self._pace_realtime:
                next_frame_at += len(raw) / 2 / self.sample_rate
                time.sleep(max(0, next_frame_at - time.monotonic()))

    def close(self) -> None:
        self._wave.close()
