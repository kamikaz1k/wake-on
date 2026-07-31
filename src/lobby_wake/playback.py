from __future__ import annotations

import queue
import threading
from collections.abc import Callable


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
        self._queue: queue.Queue[tuple[bytes, Callable[[], None] | None] | None] = (
            queue.Queue(maxsize=256)
        )
        self._thread: threading.Thread | None = None
        self._stream = None
        self._playing = threading.Event()

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

    def enqueue(self, pcm16: bytes, on_start: Callable[[], None] | None = None) -> None:
        if not pcm16:
            return
        try:
            self._queue.put_nowait((pcm16, on_start))
        except queue.Full:
            # Keep latency bounded. Dropping the oldest delta is preferable to
            # playing stale speech several seconds later.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait((pcm16, on_start))
            except queue.Empty:
                pass

    def clear(self) -> None:
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                return

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
            pcm16, on_start = item
            self._playing.set()
            try:
                if on_start is not None:
                    on_start()
                self._stream.write(pcm16)
            finally:
                self._playing.clear()
