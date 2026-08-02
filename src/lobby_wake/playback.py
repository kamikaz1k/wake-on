from __future__ import annotations

import queue
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class PlaybackPosition:
    item_id: str
    content_index: int
    audio_end_ms: int


@dataclass(frozen=True, slots=True)
class _PlaybackChunk:
    pcm16: bytes
    item_id: str
    content_index: int
    on_start: Callable[[], None] | None
    generation: int


class AudioPlayer:
    """Non-blocking mono PCM16 playback backed by sounddevice."""

    def __init__(
        self,
        *,
        sample_rate: int = 24_000,
        device: int | str | None = None,
    ) -> None:
        self.sample_rate = sample_rate
        self._device = device
        self._queue: queue.Queue[_PlaybackChunk | None] = queue.Queue(maxsize=256)
        self._thread: threading.Thread | None = None
        self._stream = None
        self._playing = threading.Event()
        self._state_lock = threading.Lock()
        self._generation = 0
        self._played_samples: dict[tuple[str, int], int] = {}
        self._latest_key: tuple[str, int] | None = None
        self._current_key: tuple[str, int] | None = None
        self._current_started_at_ns: int | None = None
        self._current_sample_count = 0

    @property
    def playing(self) -> bool:
        return self._playing.is_set() or not self._queue.empty()

    def start(self) -> None:
        if self._thread is not None:
            return

        import sounddevice as sd

        self._stream = sd.RawOutputStream(
            samplerate=self.sample_rate,
            device=self._device,
            channels=1,
            dtype="int16",
        )
        self._stream.start()
        self._thread = threading.Thread(
            target=self._playback_loop,
            name="lobby-audio-output",
            daemon=True,
        )
        self._thread.start()

    def enqueue(
        self,
        pcm16: bytes,
        on_start: Callable[[], None] | None = None,
        *,
        item_id: str = "",
        content_index: int = 0,
    ) -> None:
        if not pcm16:
            return
        with self._state_lock:
            self._latest_key = (item_id, content_index)
            generation = self._generation
        chunk = _PlaybackChunk(pcm16, item_id, content_index, on_start, generation)
        try:
            self._queue.put_nowait(chunk)
        except queue.Full:
            # Keep latency bounded. Dropping the oldest delta is preferable to
            # playing stale speech several seconds later.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait(chunk)
            except queue.Empty:
                pass

    def clear(self) -> None:
        self.interrupt()

    def interrupt(
        self,
        item_id: str | None = None,
        content_index: int = 0,
    ) -> PlaybackPosition | None:
        """Immediately discard playback and return the estimated heard position."""
        interrupted_at_ns = time.monotonic_ns()
        with self._state_lock:
            key = (item_id, content_index) if item_id is not None else self._latest_key
            played_samples = self._played_samples.get(key, 0) if key is not None else 0
            if (
                key is not None
                and self._current_key == key
                and self._current_started_at_ns is not None
            ):
                elapsed_samples = round(
                    (interrupted_at_ns - self._current_started_at_ns)
                    / 1_000_000_000
                    * self.sample_rate
                )
                played_samples += min(self._current_sample_count, max(0, elapsed_samples))
            was_playing = self._playing.is_set()
            self._generation += 1
            self._current_key = None
            self._current_started_at_ns = None
            self._current_sample_count = 0
            self._played_samples.clear()
            self._latest_key = None
            self._playing.clear()

        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break

        if was_playing and self._stream is not None:
            try:
                self._stream.abort()
                self._stream.start()
            except Exception:
                # The playback worker suppresses the matching aborted-write error.
                pass

        if key is None:
            return None
        output_latency_seconds = float(getattr(self._stream, "latency", 0.0) or 0.0)
        heard_samples = max(0, played_samples - round(output_latency_seconds * self.sample_rate))
        return PlaybackPosition(
            item_id=key[0],
            content_index=key[1],
            audio_end_ms=heard_samples * 1000 // self.sample_rate,
        )

    def close(self) -> None:
        if self._thread is not None:
            self._queue.put(None)
            self._thread.join(timeout=2)
            self._thread = None
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def _playback_loop(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                return
            pcm16 = item.pcm16
            key = (item.item_id, item.content_index)
            sample_count = len(pcm16) // 2
            with self._state_lock:
                if item.generation != self._generation:
                    continue
                generation = item.generation
                self._current_key = key
                self._current_started_at_ns = time.monotonic_ns()
                self._current_sample_count = sample_count
                self._playing.set()
            try:
                if item.on_start is not None:
                    item.on_start()
                self._stream.write(pcm16)
            except Exception:
                with self._state_lock:
                    interrupted = generation != self._generation
                if not interrupted:
                    raise
            finally:
                with self._state_lock:
                    if generation == self._generation:
                        self._played_samples[key] = (
                            self._played_samples.get(key, 0) + sample_count
                        )
                        self._current_key = None
                        self._current_started_at_ns = None
                        self._current_sample_count = 0
                        self._playing.clear()
