from __future__ import annotations

import time
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from .conversation import ConversationHandle, EndConversationRequest
from .events import EventLogger, WakeEvent
from .ring_buffer import FloatAudio


class AudioInputOwnership(StrEnum):
    """Which side owns conversation-time microphone capture."""

    HARNESS = "harness"
    DELEGATE = "delegate"


class DelegateHealth(StrEnum):
    """Backend-neutral readiness exposed to the wake harness."""

    CREATED = "created"
    READY = "ready"
    DEGRADED = "degraded"
    FAILED = "failed"
    CLOSED = "closed"


@dataclass(frozen=True, slots=True)
class DelegateCapabilities:
    audio_input: AudioInputOwnership = AudioInputOwnership.HARNESS


@dataclass(frozen=True, slots=True)
class DelegateStatus:
    health: DelegateHealth
    accepting_activation: bool
    warm: bool = False
    detail: str | None = None


@dataclass(frozen=True, slots=True)
class DelegatePrepareContext:
    """Information available before a wake is accepted."""

    sample_rate: int


@dataclass(frozen=True, slots=True)
class DelegateStartContext:
    """Conversation-scoped activation delivered after a wake is accepted."""

    wake: WakeEvent
    conversation: ConversationHandle
    sample_rate: int
    initial_audio: FloatAudio | None
    route_id: str = "default"


class ConversationDelegate(Protocol):
    """Backend-neutral conversation lifecycle driven by the wake harness.

    ``prepare`` is called before wake listening begins. Implementations may use
    it to load models, start a process, or establish a warm connection. It must
    be idempotent and may finish warming asynchronously. ``start`` must still
    support a cold activation whenever ``status.accepting_activation`` is true.
    """

    @property
    def capabilities(self) -> DelegateCapabilities: ...

    @property
    def status(self) -> DelegateStatus: ...

    @property
    def active(self) -> bool: ...

    def prepare(self, context: DelegatePrepareContext) -> None: ...

    def start(self, context: DelegateStartContext) -> None: ...

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None: ...

    def poll(self) -> None: ...

    def request_end(self, request: EndConversationRequest) -> None: ...

    def stop(self) -> None: ...

    def close(self) -> None: ...


# Transitional alias for callers that used the original name.
ConversationAgent = ConversationDelegate


class MockConversationAgent:
    """A deterministic delegate used by tests and local harness demos."""

    def __init__(self, logger: EventLogger, duration_seconds: float = 3.0) -> None:
        self._logger = logger
        self._duration_ns = round(duration_seconds * 1_000_000_000)
        self._started_at_ns: int | None = None
        self._audio_samples = 0
        self._prepared = False
        self._closed = False

    @property
    def capabilities(self) -> DelegateCapabilities:
        return DelegateCapabilities()

    @property
    def status(self) -> DelegateStatus:
        if self._closed:
            return DelegateStatus(DelegateHealth.CLOSED, accepting_activation=False)
        return DelegateStatus(
            DelegateHealth.READY if self._prepared else DelegateHealth.CREATED,
            accepting_activation=self._prepared,
            warm=self._prepared,
        )

    @property
    def active(self) -> bool:
        return self._started_at_ns is not None

    def prepare(self, context: DelegatePrepareContext) -> None:
        self._prepared = True
        self._logger.emit(
            "delegate.prepared",
            adapter="mock",
            sample_rate=context.sample_rate,
            warm=True,
        )

    def start(self, context: DelegateStartContext) -> None:
        self._started_at_ns = time.monotonic_ns()
        initial_audio = context.initial_audio
        self._audio_samples = initial_audio.size if initial_audio is not None else 0
        self._logger.emit(
            "delegate.started",
            adapter="mock",
            route_id=context.route_id,
            wake_phrase=context.wake.phrase,
            wake_to_agent_start_ms=(
                self._started_at_ns - context.wake.detected_at_ns
            )
            / 1_000_000,
            initial_audio_ms=(
                initial_audio.size / context.sample_rate * 1000
                if initial_audio is not None
                else 0
            ),
        )

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None:
        del sample_rate
        self._audio_samples += samples.size

    def poll(self) -> None:
        if self._started_at_ns is None:
            return
        if time.monotonic_ns() - self._started_at_ns >= self._duration_ns:
            self.stop()

    def request_end(self, request: EndConversationRequest) -> None:
        self._logger.emit(
            "delegate.end_requested",
            adapter="mock",
            source=request.source,
            reason=request.reason,
            mode=request.mode,
        )
        self.stop()

    def stop(self) -> None:
        if self._started_at_ns is None:
            return
        self._logger.emit(
            "delegate.stopped",
            adapter="mock",
            duration_ms=(time.monotonic_ns() - self._started_at_ns) / 1_000_000,
            audio_samples=self._audio_samples,
        )
        self._started_at_ns = None

    def close(self) -> None:
        self.stop()
        self._closed = True
