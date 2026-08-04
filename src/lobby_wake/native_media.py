from __future__ import annotations

import contextlib
import json
import queue
import struct
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import numpy as np

from .events import EventLogger
from .playback import PlaybackPosition
from .ring_buffer import FloatAudio

FRAME_HEADER = struct.Struct(">cI")
CHUNK_ID = struct.Struct(">Q")
MAX_FRAME_BYTES = 4 * 1024 * 1024
DEFAULT_NATIVE_MEDIA_HELPER = Path("native/macos-media-helper/bin/wake-on-media-helper")


def encode_media_frame(frame_type: bytes, payload: bytes = b"") -> bytes:
    if len(frame_type) != 1:
        raise ValueError("media frame type must be one byte")
    if len(payload) > MAX_FRAME_BYTES:
        raise ValueError("media frame is too large")
    return FRAME_HEADER.pack(frame_type, len(payload)) + payload


def read_media_frame(stream: BinaryIO) -> tuple[bytes, bytes]:
    header = _read_exactly(stream, FRAME_HEADER.size)
    frame_type, length = FRAME_HEADER.unpack(header)
    if length > MAX_FRAME_BYTES:
        raise ValueError("native media frame is too large")
    return frame_type, _read_exactly(stream, length)


def _read_exactly(stream: BinaryIO, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise EOFError("native media helper closed its stream")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


@dataclass(slots=True)
class _NativePlaybackChunk:
    item_id: str
    content_index: int
    sample_count: int
    on_start: Callable[[], None] | None


class NativeMacMedia:
    """Voice-processed macOS capture/playback backed by the Swift helper."""

    sample_rate = 24_000

    def __init__(
        self,
        logger: EventLogger,
        command: Sequence[str | Path] = (DEFAULT_NATIVE_MEDIA_HELPER,),
        *,
        start_timeout_seconds: float = 30.0,
    ) -> None:
        if not command:
            raise ValueError("native media helper command cannot be empty")
        self._logger = logger
        self._command = tuple(str(part) for part in command)
        self._start_timeout_seconds = start_timeout_seconds
        self._process: subprocess.Popen[bytes] | None = None
        self._reader_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._ready = threading.Event()
        self._playing = threading.Event()
        self._capture_handler: Callable[[FloatAudio, int], None] | None = None
        self._wake_capture_handler: Callable[[FloatAudio, int], None] | None = None
        self._capture_active = False
        self._capture_preroll: deque[bytes] = deque()
        self._capture_preroll_samples = 0
        self._start_error: str | None = None
        self._capture_sample_rate = 0
        self._output_latency_seconds = 0.0
        self._next_chunk_id = 1
        self._chunks: dict[int, _NativePlaybackChunk] = {}
        self._playback_order: deque[int] = deque()
        self._current_started_at_ns: int | None = None
        self._played_samples: dict[tuple[str, int], int] = {}
        self._latest_key: tuple[str, int] | None = None

    @property
    def playing(self) -> bool:
        return self._playing.is_set()

    @property
    def running(self) -> bool:
        process = self._process
        return process is not None and process.poll() is None

    def set_capture_handler(self, handler: Callable[[FloatAudio, int], None]) -> None:
        self._capture_handler = handler

    def set_wake_capture_handler(
        self,
        handler: Callable[[FloatAudio, int], None],
    ) -> None:
        self._wake_capture_handler = handler

    def activate_capture(self) -> None:
        with self._state_lock:
            self._capture_active = True
            preroll = list(self._capture_preroll)
            self._capture_preroll.clear()
            self._capture_preroll_samples = 0
        for payload in preroll:
            self._deliver_capture(payload)

    def deactivate_capture(self) -> None:
        with self._state_lock:
            self._capture_active = False
            self._capture_preroll.clear()
            self._capture_preroll_samples = 0

    def start(self) -> None:
        if self._process is not None:
            return
        helper = Path(self._command[0])
        if len(self._command) == 1 and not helper.exists():
            raise FileNotFoundError(
                f"native media helper not found at {helper}; "
                "run sh scripts/build-native-media-helper.sh"
            )
        started_at_ns = time.monotonic_ns()
        self._process = subprocess.Popen(
            self._command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._reader_thread = threading.Thread(
            target=self._reader_loop,
            name="wake-on-native-media-reader",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._stderr_loop,
            name="wake-on-native-media-stderr",
            daemon=True,
        )
        self._reader_thread.start()
        self._stderr_thread.start()
        if not self._ready.wait(self._start_timeout_seconds):
            self.close()
            raise TimeoutError("native media helper did not become ready")
        if self._start_error is not None:
            error = self._start_error
            self.close()
            raise RuntimeError(error)
        self._logger.emit(
            "media.native_ready",
            helper=self._command[0],
            setup_ms=(time.monotonic_ns() - started_at_ns) / 1_000_000,
            capture_sample_rate=self._capture_sample_rate,
            playback_sample_rate=self.sample_rate,
            output_latency_ms=self._output_latency_seconds * 1_000,
            voice_processing=True,
        )

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
        if len(pcm16) % 2:
            raise ValueError("native playback requires PCM16 bytes")
        with self._state_lock:
            chunk_id = self._next_chunk_id
            self._next_chunk_id += 1
            was_idle = not self._playback_order
            self._chunks[chunk_id] = _NativePlaybackChunk(
                item_id,
                content_index,
                len(pcm16) // 2,
                on_start,
            )
            self._playback_order.append(chunk_id)
            self._latest_key = (item_id, content_index)
            if was_idle:
                self._current_started_at_ns = time.monotonic_ns()
                self._playing.set()
        self._send_frame(b"P", CHUNK_ID.pack(chunk_id) + pcm16)
        if was_idle and on_start is not None:
            on_start()

    def clear(self) -> None:
        self.interrupt()

    def interrupt(
        self,
        item_id: str | None = None,
        content_index: int = 0,
    ) -> PlaybackPosition | None:
        interrupted_at_ns = time.monotonic_ns()
        with self._state_lock:
            key = (item_id, content_index) if item_id is not None else self._latest_key
            played_samples = self._played_samples.get(key, 0) if key is not None else 0
            if key is not None and self._playback_order:
                current = self._chunks.get(self._playback_order[0])
                if (
                    current is not None
                    and (current.item_id, current.content_index) == key
                    and self._current_started_at_ns is not None
                ):
                    elapsed = round(
                        (interrupted_at_ns - self._current_started_at_ns)
                        / 1_000_000_000
                        * self.sample_rate
                    )
                    played_samples += min(current.sample_count, max(0, elapsed))
            self._chunks.clear()
            self._playback_order.clear()
            self._played_samples.clear()
            self._latest_key = None
            self._current_started_at_ns = None
            self._playing.clear()
        process = self._process
        if process is not None and process.poll() is None:
            # SIGINT reaches the helper's process group too. Its pipe can close
            # before the parent delegate performs final cleanup.
            with contextlib.suppress(BrokenPipeError, OSError):
                self._send_frame_to(process, b"C")
        if key is None:
            return None
        heard_samples = max(
            0,
            played_samples - round(self._output_latency_seconds * self.sample_rate),
        )
        return PlaybackPosition(
            item_id=key[0],
            content_index=key[1],
            audio_end_ms=heard_samples * 1000 // self.sample_rate,
        )

    def close(self) -> None:
        process, self._process = self._process, None
        if process is None:
            return
        try:
            if process.poll() is None:
                self._send_frame_to(process, b"Q")
                process.wait(timeout=2)
        except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        finally:
            if process.stdin is not None:
                process.stdin.close()
        if self._reader_thread is not None:
            self._reader_thread.join(timeout=1)
            self._reader_thread = None
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=1)
            self._stderr_thread = None
        self._ready.clear()
        self._playing.clear()
        self._logger.emit("media.native_stopped", return_code=process.returncode)

    def _reader_loop(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        try:
            while True:
                frame_type, payload = read_media_frame(process.stdout)
                self._handle_frame(frame_type, payload)
        except EOFError:
            if not self._ready.is_set():
                self._start_error = "native media helper exited before becoming ready"
                self._ready.set()
        except (OSError, ValueError) as error:
            self._logger.emit("media.native_protocol_error", detail=str(error))
            if not self._ready.is_set():
                self._start_error = str(error)
                self._ready.set()

    def _stderr_loop(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        for line in iter(process.stderr.readline, b""):
            detail = line.decode("utf-8", errors="replace").strip()
            if detail:
                self._logger.emit("media.native_stderr", detail=detail[:500])

    def _handle_frame(self, frame_type: bytes, payload: bytes) -> None:
        if frame_type == b"R":
            ready = json.loads(payload)
            if not isinstance(ready, dict) or ready.get("voice_processing") is not True:
                raise ValueError("native helper did not enable voice processing")
            self._capture_sample_rate = int(ready["capture_sample_rate"])
            self._output_latency_seconds = float(ready.get("output_latency_ms", 0)) / 1_000
            self._ready.set()
        elif frame_type == b"A":
            if self._capture_sample_rate <= 0:
                raise ValueError("native helper sent audio before readiness")
            samples = self._decode_capture(payload)
            wake_handler = self._wake_capture_handler
            if wake_handler is not None and samples.size:
                wake_handler(samples, self._capture_sample_rate)
            with self._state_lock:
                capture_active = self._capture_active
                if not capture_active and payload:
                    self._capture_preroll.append(payload)
                    self._capture_preroll_samples += len(payload) // 2
                    while (
                        self._capture_preroll
                        and self._capture_preroll_samples > self._capture_sample_rate
                    ):
                        removed = self._capture_preroll.popleft()
                        self._capture_preroll_samples -= len(removed) // 2
            if capture_active:
                self._deliver_capture_samples(samples)
        elif frame_type == b"D":
            if len(payload) != CHUNK_ID.size:
                raise ValueError("native playback completion has an invalid chunk ID")
            self._finish_playback_chunk(CHUNK_ID.unpack(payload)[0])
        elif frame_type == b"E":
            error = json.loads(payload)
            detail = error.get("message", "native media helper failed")
            self._logger.emit("media.native_error", detail=detail)
            if not self._ready.is_set():
                self._start_error = str(detail)
                self._ready.set()
        else:
            raise ValueError(f"unknown native media frame: {frame_type!r}")

    def _finish_playback_chunk(self, chunk_id: int) -> None:
        with self._state_lock:
            chunk = self._chunks.pop(chunk_id, None)
            if chunk is None:
                return
            try:
                self._playback_order.remove(chunk_id)
            except ValueError:
                return
            key = (chunk.item_id, chunk.content_index)
            self._played_samples[key] = self._played_samples.get(key, 0) + chunk.sample_count
            if self._playback_order:
                self._current_started_at_ns = time.monotonic_ns()
            else:
                self._current_started_at_ns = None
                self._playing.clear()

    def _deliver_capture(self, payload: bytes) -> None:
        self._deliver_capture_samples(self._decode_capture(payload))

    def _deliver_capture_samples(self, samples: FloatAudio) -> None:
        handler = self._capture_handler
        if handler is None or not samples.size:
            return
        handler(samples, self._capture_sample_rate)

    @staticmethod
    def _decode_capture(payload: bytes) -> FloatAudio:
        if not payload:
            return np.empty(0, dtype=np.float32)
        return np.frombuffer(payload, dtype="<i2").astype(np.float32) / 32768.0

    def _send_frame(self, frame_type: bytes, payload: bytes = b"") -> None:
        process = self._process
        if process is None:
            raise RuntimeError("native media helper is not running")
        self._send_frame_to(process, frame_type, payload)

    def _send_frame_to(
        self,
        process: subprocess.Popen[bytes],
        frame_type: bytes,
        payload: bytes = b"",
    ) -> None:
        if process.stdin is None:
            raise BrokenPipeError("native media helper stdin is closed")
        frame = encode_media_frame(frame_type, payload)
        with self._write_lock:
            process.stdin.write(frame)
            process.stdin.flush()


class NativeWakeAudioSource:
    """16 kHz wake-detector view over NativeMacMedia's continuous capture."""

    sample_rate = 16_000

    def __init__(self, media: NativeMacMedia, *, queue_size: int = 32) -> None:
        if queue_size <= 0:
            raise ValueError("native wake audio queue size must be positive")
        self._media = media
        self._queue: queue.Queue[FloatAudio | None] = queue.Queue(maxsize=queue_size)
        self._closed = threading.Event()
        media.set_wake_capture_handler(self._accept_capture)

    def frames(self) -> Iterator[FloatAudio]:
        while True:
            try:
                samples = self._queue.get(timeout=0.25)
            except queue.Empty:
                if not self._media.running:
                    return
                continue
            if samples is None:
                return
            yield samples

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        self._put_latest(None)

    def _accept_capture(self, samples: FloatAudio, source_rate: int) -> None:
        if self._closed.is_set() or not samples.size:
            return
        wake_samples = self._resample(samples, source_rate, self.sample_rate)
        self._put_latest(wake_samples)

    def _put_latest(self, samples: FloatAudio | None) -> None:
        try:
            self._queue.put_nowait(samples)
        except queue.Full:
            # Preserve bounded latency if wake processing ever falls behind.
            with contextlib.suppress(queue.Empty):
                self._queue.get_nowait()
            with contextlib.suppress(queue.Full):
                self._queue.put_nowait(samples)

    @staticmethod
    def _resample(
        samples: FloatAudio,
        source_rate: int,
        target_rate: int,
    ) -> FloatAudio:
        if source_rate <= 0:
            raise ValueError("native capture sample rate must be positive")
        samples = np.asarray(samples, dtype=np.float32)
        if source_rate == target_rate:
            return samples
        target_size = max(1, round(samples.size * target_rate / source_rate))
        source_positions = np.arange(samples.size, dtype=np.float64)
        target_positions = (
            np.arange(target_size, dtype=np.float64) * source_rate / target_rate
        )
        return np.interp(target_positions, source_positions, samples).astype(np.float32)
