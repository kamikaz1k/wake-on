from __future__ import annotations

from enum import StrEnum

from .agent import ConversationAgent
from .events import EventLogger
from .ring_buffer import AudioRingBuffer, FloatAudio
from .wake import WakeWordEngine


class State(StrEnum):
    LISTENING = "listening"
    CONVERSATION = "conversation"


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
    ) -> None:
        self.state = State.LISTENING
        self._detector = detector
        self._agent = agent
        self._logger = logger
        self._sample_rate = sample_rate
        self._ring = AudioRingBuffer(sample_rate, preroll_seconds)

    def prepare(self) -> None:
        self._agent.prepare()
        self._logger.emit("orchestrator.ready", state=self.state)

    def process(self, samples: FloatAudio) -> None:
        self._ring.append(samples)
        if self.state is State.LISTENING:
            wake = self._detector.process(samples, self._sample_rate)
            if wake is None:
                return
            initial_audio = self._ring.snapshot()
            self._logger.emit(
                "wake.detected",
                phrase=wake.phrase,
                buffered_audio_ms=initial_audio.size / self._sample_rate * 1000,
            )
            self._agent.start(initial_audio, self._sample_rate, wake)
            self.state = State.CONVERSATION
            self._logger.emit("orchestrator.state", state=self.state)
            return

        self._agent.send_audio(samples, self._sample_rate)
        self._agent.poll()
        if not self._agent.active:
            self._detector.reset()
            self._ring.clear()
            self.state = State.LISTENING
            self._logger.emit("orchestrator.state", state=self.state)

    def close(self) -> None:
        self._agent.close()
