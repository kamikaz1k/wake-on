from __future__ import annotations

import time

import numpy as np

from lobby_wake.agent import MockConversationAgent
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.orchestrator import Orchestrator, State


class TriggerOnce:
    def __init__(self) -> None:
        self.triggered = False
        self.reset_count = 0

    def process(self, samples: np.ndarray, sample_rate: int) -> WakeEvent | None:
        del samples, sample_rate
        if self.triggered:
            return None
        self.triggered = True
        return WakeEvent("HEY LOBBY", time.monotonic_ns())

    def reset(self) -> None:
        self.reset_count += 1


def test_trigger_hands_preroll_to_agent_and_returns_to_listening() -> None:
    detector = TriggerOnce()
    logger = EventLogger()
    agent = MockConversationAgent(logger, duration_seconds=0)
    orchestrator = Orchestrator(
        detector,
        agent,
        logger,
        sample_rate=10,
        preroll_seconds=1,
    )

    orchestrator.prepare()
    orchestrator.process(np.ones(6, dtype=np.float32))
    assert orchestrator.state is State.CONVERSATION

    orchestrator.process(np.ones(2, dtype=np.float32))
    assert orchestrator.state is State.LISTENING
    assert detector.reset_count == 1

