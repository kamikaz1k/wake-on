from __future__ import annotations

from collections import deque

import numpy as np
import numpy.typing as npt

FloatAudio = npt.NDArray[np.float32]


class AudioRingBuffer:
    """A bounded mono float32 audio buffer."""

    def __init__(self, sample_rate: int, duration_seconds: float) -> None:
        if sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        if duration_seconds <= 0:
            raise ValueError("duration_seconds must be positive")
        self._capacity = max(1, round(sample_rate * duration_seconds))
        self._chunks: deque[FloatAudio] = deque()
        self._sample_count = 0

    @property
    def sample_count(self) -> int:
        return self._sample_count

    def append(self, samples: FloatAudio) -> None:
        chunk = np.asarray(samples, dtype=np.float32).reshape(-1).copy()
        if chunk.size == 0:
            return
        self._chunks.append(chunk)
        self._sample_count += chunk.size
        self._trim()

    def snapshot(self) -> FloatAudio:
        if not self._chunks:
            return np.empty(0, dtype=np.float32)
        return np.concatenate(tuple(self._chunks))

    def clear(self) -> None:
        self._chunks.clear()
        self._sample_count = 0

    def _trim(self) -> None:
        overflow = self._sample_count - self._capacity
        while overflow > 0 and self._chunks:
            first = self._chunks[0]
            if first.size <= overflow:
                self._chunks.popleft()
                self._sample_count -= first.size
                overflow -= first.size
                continue
            self._chunks[0] = first[overflow:].copy()
            self._sample_count -= overflow
            overflow = 0

