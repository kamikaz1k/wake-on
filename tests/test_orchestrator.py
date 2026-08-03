from __future__ import annotations

import time

import numpy as np

from lobby_wake.agent import (
    AudioInputOwnership,
    DelegateCapabilities,
    DelegateHealth,
    DelegatePrepareContext,
    DelegateStartContext,
    DelegateStatus,
    MockConversationAgent,
)
from lobby_wake.conversation import ConversationController, EndConversationRequest, EndMode
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


class EndingAgent:
    def __init__(self) -> None:
        self.active = False
        self.end_request: EndConversationRequest | None = None
        self.prepare_context: DelegatePrepareContext | None = None
        self.start_context: DelegateStartContext | None = None

    @property
    def capabilities(self) -> DelegateCapabilities:
        return DelegateCapabilities()

    @property
    def status(self) -> DelegateStatus:
        return DelegateStatus(
            DelegateHealth.READY,
            accepting_activation=self.prepare_context is not None,
            warm=self.prepare_context is not None,
        )

    def prepare(self, context: DelegatePrepareContext) -> None:
        self.prepare_context = context

    def start(self, context: DelegateStartContext) -> None:
        self.start_context = context
        self.active = True

    def send_audio(self, samples: np.ndarray, sample_rate: int) -> None:
        del samples, sample_rate

    def poll(self) -> None:
        pass

    def request_end(self, request: EndConversationRequest) -> None:
        self.end_request = request
        if request.mode is EndMode.IMMEDIATE:
            self.active = False

    def stop(self) -> None:
        self.active = False

    def close(self) -> None:
        self.stop()


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


def test_prepare_runs_before_wake_and_start_receives_conversation_context() -> None:
    detector = TriggerOnce()
    logger = EventLogger()
    agent = EndingAgent()
    orchestrator = Orchestrator(detector, agent, logger, sample_rate=16_000)

    orchestrator.prepare()

    assert agent.prepare_context == DelegatePrepareContext(sample_rate=16_000)
    assert agent.start_context is None

    orchestrator.process(np.ones(320, dtype=np.float32))

    assert agent.start_context is not None
    assert agent.start_context.wake.phrase == "HEY LOBBY"
    assert agent.start_context.initial_audio is not None
    assert agent.start_context.conversation is orchestrator.conversation_handle
    logger.close()


def test_delegate_owned_input_does_not_receive_harness_audio() -> None:
    class DelegateOwnedInputAgent(EndingAgent):
        def __init__(self) -> None:
            super().__init__()
            self.sent_audio_blocks = 0

        @property
        def capabilities(self) -> DelegateCapabilities:
            return DelegateCapabilities(audio_input=AudioInputOwnership.DELEGATE)

        def send_audio(self, samples: np.ndarray, sample_rate: int) -> None:
            del samples, sample_rate
            self.sent_audio_blocks += 1

    detector = TriggerOnce()
    logger = EventLogger()
    agent = DelegateOwnedInputAgent()
    orchestrator = Orchestrator(detector, agent, logger, sample_rate=16_000)
    orchestrator.prepare()

    orchestrator.process(np.ones(320, dtype=np.float32))
    orchestrator.process(np.ones(320, dtype=np.float32))

    assert agent.start_context is not None
    assert agent.start_context.initial_audio is None
    assert agent.sent_audio_blocks == 0
    logger.close()


def test_unavailable_delegate_does_not_begin_conversation() -> None:
    class UnavailableAgent(EndingAgent):
        @property
        def status(self) -> DelegateStatus:
            return DelegateStatus(
                DelegateHealth.FAILED,
                accepting_activation=False,
                detail="worker unavailable",
            )

    detector = TriggerOnce()
    logger = EventLogger()
    agent = UnavailableAgent()
    orchestrator = Orchestrator(detector, agent, logger, sample_rate=16_000)
    orchestrator.prepare()

    orchestrator.process(np.ones(320, dtype=np.float32))

    assert orchestrator.state is State.LISTENING
    assert agent.start_context is None
    assert detector.reset_count == 1
    logger.close()


def test_graceful_end_enters_ending_until_agent_finishes() -> None:
    detector = TriggerOnce()
    logger = EventLogger()
    controller = ConversationController(logger)
    agent = EndingAgent()
    orchestrator = Orchestrator(
        detector,
        agent,
        logger,
        sample_rate=10,
        conversation_controller=controller,
    )
    orchestrator.prepare()
    orchestrator.process(np.ones(6, dtype=np.float32))

    controller.handle.end(reason="task_complete")
    orchestrator.process(np.ones(2, dtype=np.float32))

    assert orchestrator.state is State.ENDING
    assert agent.end_request is not None
    agent.active = False
    orchestrator.process(np.ones(2, dtype=np.float32))
    assert orchestrator.state is State.LISTENING
    logger.close()


def test_immediate_end_returns_directly_to_listening() -> None:
    detector = TriggerOnce()
    logger = EventLogger()
    controller = ConversationController(logger)
    agent = EndingAgent()
    orchestrator = Orchestrator(
        detector,
        agent,
        logger,
        sample_rate=10,
        conversation_controller=controller,
    )
    orchestrator.prepare()
    orchestrator.process(np.ones(6, dtype=np.float32))

    controller.handle.kill()
    orchestrator.process(np.ones(2, dtype=np.float32))

    assert orchestrator.state is State.LISTENING
    assert agent.end_request is not None
    assert agent.end_request.mode is EndMode.IMMEDIATE
    logger.close()
