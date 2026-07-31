from __future__ import annotations

import time
from typing import Protocol

from .events import EventLogger, WakeEvent
from .ring_buffer import FloatAudio


class ConversationAgent(Protocol):
    @property
    def active(self) -> bool: ...

    def prepare(self) -> None: ...

    def start(self, initial_audio: FloatAudio, sample_rate: int, wake: WakeEvent) -> None: ...

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None: ...

    def poll(self) -> None: ...

    def stop(self) -> None: ...


class MockConversationAgent:
    """A deterministic stand-in for the future OpenAI Realtime adapter."""

    def __init__(self, logger: EventLogger, duration_seconds: float = 3.0) -> None:
        self._logger = logger
        self._duration_ns = round(duration_seconds * 1_000_000_000)
        self._started_at_ns: int | None = None
        self._audio_samples = 0

    @property
    def active(self) -> bool:
        return self._started_at_ns is not None

    def prepare(self) -> None:
        self._logger.emit("agent.prepared", adapter="mock")

    def start(self, initial_audio: FloatAudio, sample_rate: int, wake: WakeEvent) -> None:
        self._started_at_ns = time.monotonic_ns()
        self._audio_samples = initial_audio.size
        self._logger.emit(
            "agent.started",
            adapter="mock",
            wake_phrase=wake.phrase,
            wake_to_agent_start_ms=(self._started_at_ns - wake.detected_at_ns) / 1_000_000,
            initial_audio_ms=initial_audio.size / sample_rate * 1000,
        )

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None:
        del sample_rate
        self._audio_samples += samples.size

    def poll(self) -> None:
        if self._started_at_ns is None:
            return
        if time.monotonic_ns() - self._started_at_ns >= self._duration_ns:
            self.stop()

    def stop(self) -> None:
        if self._started_at_ns is None:
            return
        self._logger.emit(
            "agent.stopped",
            adapter="mock",
            duration_ms=(time.monotonic_ns() - self._started_at_ns) / 1_000_000,
            audio_samples=self._audio_samples,
        )
        self._started_at_ns = None

