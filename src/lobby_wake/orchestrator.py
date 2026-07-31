from __future__ import annotations

import time
from enum import StrEnum

from .agent import ConversationAgent
from .conversation import (
    ConversationController,
    ConversationHandle,
    EndMode,
    EndSource,
)
from .events import EventLogger
from .ring_buffer import AudioRingBuffer, FloatAudio, estimate_speech_tail
from .wake import WakeWordEngine


class State(StrEnum):
    LISTENING = "listening"
    CONVERSATION = "conversation"
    ENDING = "ending"


class Orchestrator:
    """Routes one audio stream between wake detection and conversation."""

    def __init__(
        self,
        detector: WakeWordEngine,
        agent: ConversationAgent,
        logger: EventLogger,
        *,
        sample_rate: int,
        preroll_seconds: float = 1.0,
        conversation_controller: ConversationController | None = None,
    ) -> None:
        self.state = State.LISTENING
        self._detector = detector
        self._agent = agent
        self._logger = logger
        self._sample_rate = sample_rate
        self._ring = AudioRingBuffer(sample_rate, preroll_seconds)
        self._conversation = conversation_controller or ConversationController(logger)
        self._ending_request = None
        self._ending_started_at_ns: int | None = None

    @property
    def conversation_handle(self) -> ConversationHandle:
        return self._conversation.handle

    def prepare(self) -> None:
        self._agent.prepare()
        self._logger.emit("orchestrator.ready", state=self.state)

    def process(self, samples: FloatAudio) -> None:
        self._ring.append(samples)
        if self.state is State.LISTENING:
            detector_call_started_ns = time.monotonic_ns()
            wake = self._detector.process(samples, self._sample_rate)
            detector_call_ms = (time.monotonic_ns() - detector_call_started_ns) / 1_000_000
            if wake is None:
                return
            self._logger.emit(
                "wake.detected",
                phrase=wake.phrase,
                wake_detected_at_ns=wake.detected_at_ns,
                buffered_audio_ms=self._ring.sample_count / self._sample_rate * 1000,
                audio_frame_ms=samples.size / self._sample_rate * 1000,
                detector_call_ms=detector_call_ms,
            )
            self._logger.emit(
                "activation.listening",
                wake_to_feedback_ms=(time.monotonic_ns() - wake.detected_at_ns) / 1_000_000,
            )
            initial_audio = self._ring.snapshot()
            speech_tail = estimate_speech_tail(initial_audio, self._sample_rate)
            if speech_tail is not None:
                self._logger.emit(
                    "wake.speech_tail_estimated",
                    estimated_speech_end_to_wake_ms=(
                        speech_tail.trailing_silence_ms + detector_call_ms
                    ),
                    trailing_silence_ms=speech_tail.trailing_silence_ms,
                    speech_rms_threshold=speech_tail.rms_threshold,
                )
            self._conversation.begin()
            self._agent.start(initial_audio, self._sample_rate, wake)
            self.state = State.CONVERSATION
            self._logger.emit("orchestrator.state", state=self.state)
            return

        request = self._conversation.take_request()
        if request is not None:
            self._agent.request_end(request)
            self.state = State.ENDING
            self._ending_request = request
            self._ending_started_at_ns = time.monotonic_ns()
            self._logger.emit(
                "orchestrator.state",
                state=self.state,
                end_source=request.source,
                end_mode=request.mode,
            )

        if self.state is State.CONVERSATION:
            self._agent.send_audio(samples, self._sample_rate)
        self._agent.poll()
        if not self._agent.active:
            if self.state is State.ENDING and self._ending_request is not None:
                self._logger.emit(
                    "conversation.ended",
                    source=self._ending_request.source,
                    reason=self._ending_request.reason,
                    mode=self._ending_request.mode,
                    ending_ms=(
                        (time.monotonic_ns() - self._ending_started_at_ns) / 1_000_000
                        if self._ending_started_at_ns is not None
                        else 0
                    ),
                )
            self._detector.reset()
            self._ring.clear()
            self._conversation.finish()
            self._ending_request = None
            self._ending_started_at_ns = None
            self.state = State.LISTENING
            self._logger.emit("orchestrator.state", state=self.state)

    def request_end(
        self,
        *,
        source: EndSource = EndSource.SYSTEM,
        reason: str = "requested",
        immediate: bool = False,
        farewell: str | None = None,
    ) -> bool:
        return self._conversation.request_end(
            source=source,
            reason=reason,
            mode=EndMode.IMMEDIATE if immediate else EndMode.GRACEFUL,
            farewell=farewell,
        )

    def close(self) -> None:
        self._conversation.finish()
        self._agent.close()
