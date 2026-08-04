from __future__ import annotations

import time
from collections.abc import Iterable
from dataclasses import dataclass, field
from enum import StrEnum

from .agent import (
    AudioInputOwnership,
    ConversationDelegate,
    DelegatePrepareContext,
    DelegateStartContext,
    DelegateStatus,
)
from .conversation import (
    ConversationController,
    ConversationHandle,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from .events import EventLogger, WakeEvent, normalize_trigger_id
from .ring_buffer import AudioRingBuffer, FloatAudio, estimate_speech_tail
from .wake import WakeWordEngine


class State(StrEnum):
    LISTENING = "listening"
    CONVERSATION = "conversation"
    ENDING = "ending"


@dataclass(frozen=True, slots=True)
class WakeRoute:
    """Immutable ownership of one or more wake triggers by one delegate."""

    route_id: str
    delegate: ConversationDelegate
    trigger_ids: frozenset[str] = field(default_factory=frozenset)

    def __post_init__(self) -> None:
        route_id = normalize_trigger_id(self.route_id)
        if not route_id:
            raise ValueError("route_id cannot be empty")
        trigger_ids = frozenset(normalize_trigger_id(value) for value in self.trigger_ids)
        if "" in trigger_ids:
            raise ValueError("trigger IDs cannot be empty")
        object.__setattr__(self, "route_id", route_id)
        object.__setattr__(self, "trigger_ids", trigger_ids)

    @classmethod
    def for_trigger(
        cls,
        route_id: str,
        trigger_id: str,
        delegate: ConversationDelegate,
    ) -> WakeRoute:
        return cls(route_id, delegate, frozenset({trigger_id}))

    def matches(self, wake: WakeEvent) -> bool:
        return not self.trigger_ids or wake.trigger_id in self.trigger_ids


class WakeRouter:
    """Owns one audio stream and an exclusive activation across wake routes."""

    def __init__(
        self,
        detector: WakeWordEngine,
        routes: Iterable[WakeRoute],
        logger: EventLogger,
        *,
        sample_rate: int,
        preroll_seconds: float = 1.0,
        conversation_controller: ConversationController | None = None,
    ) -> None:
        route_list = tuple(routes)
        if not route_list:
            raise ValueError("WakeRouter requires at least one route")
        route_ids = [route.route_id for route in route_list]
        if len(set(route_ids)) != len(route_ids):
            raise ValueError("route IDs must be unique")
        delegate_ids = [id(route.delegate) for route in route_list]
        if len(set(delegate_ids)) != len(delegate_ids):
            raise ValueError("one delegate cannot be owned by multiple routes")

        trigger_routes: dict[str, WakeRoute] = {}
        fallback_route: WakeRoute | None = None
        for route in route_list:
            if not route.trigger_ids:
                if fallback_route is not None:
                    raise ValueError("only one catch-all route is allowed")
                fallback_route = route
                continue
            for trigger_id in route.trigger_ids:
                if trigger_id in trigger_routes:
                    raise ValueError(f"trigger ID {trigger_id!r} is owned by multiple routes")
                trigger_routes[trigger_id] = route

        self.state = State.LISTENING
        self._detector = detector
        self._routes = route_list
        self._routes_by_id = {route.route_id: route for route in route_list}
        self._trigger_routes = trigger_routes
        self._fallback_route = fallback_route
        self._active_route: WakeRoute | None = None
        self._logger = logger
        self._sample_rate = sample_rate
        self._ring = AudioRingBuffer(sample_rate, preroll_seconds)
        self._conversation = conversation_controller or ConversationController(logger)
        self._ending_request: EndConversationRequest | None = None
        self._ending_started_at_ns: int | None = None

    @property
    def routes(self) -> tuple[WakeRoute, ...]:
        return self._routes

    @property
    def active_route_id(self) -> str | None:
        return self._active_route.route_id if self._active_route is not None else None

    @property
    def conversation_handle(self) -> ConversationHandle:
        return self._conversation.handle

    def route_status(self, route_id: str) -> DelegateStatus:
        normalized = normalize_trigger_id(route_id)
        try:
            return self._routes_by_id[normalized].delegate.status
        except KeyError as error:
            raise KeyError(f"unknown wake route: {route_id}") from error

    def prepare(self) -> None:
        context = DelegatePrepareContext(sample_rate=self._sample_rate)
        route_statuses = []
        for route in self._routes:
            route.delegate.prepare(context)
            status = route.delegate.status
            route_statuses.append(
                {
                    "route_id": route.route_id,
                    "health": str(status.health),
                    "warm": status.warm,
                }
            )
        self._logger.emit(
            "orchestrator.ready",
            state=self.state,
            route_count=len(self._routes),
            routes=route_statuses,
        )

    def process_audio(self, samples: FloatAudio) -> None:
        self._ring.append(samples)
        if self.state is State.LISTENING:
            self._process_listening(samples)
            return
        self._process_conversation(samples)

    # Compatibility with the original streaming loop API.
    def process(self, samples: FloatAudio) -> None:
        self.process_audio(samples)

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
        for route in self._routes:
            route.delegate.close()

    def _process_listening(self, samples: FloatAudio) -> None:
        for route in self._routes:
            route.delegate.poll()
        detector_call_started_ns = time.monotonic_ns()
        wake = self._detector.process(samples, self._sample_rate)
        detector_call_ms = (time.monotonic_ns() - detector_call_started_ns) / 1_000_000
        if wake is None:
            return
        self._logger.emit(
            "wake.detected",
            phrase=wake.phrase,
            trigger_id=wake.trigger_id,
            wake_detected_at_ns=wake.detected_at_ns,
            buffered_audio_ms=self._ring.sample_count / self._sample_rate * 1000,
            audio_frame_ms=samples.size / self._sample_rate * 1000,
            detector_call_ms=detector_call_ms,
        )
        route = self._trigger_routes.get(wake.trigger_id or "") or self._fallback_route
        if route is None:
            self._logger.emit(
                "activation.unrouted",
                trigger_id=wake.trigger_id,
                phrase=wake.phrase,
            )
            self._reset_listening()
            return
        delegate_status = route.delegate.status
        if not delegate_status.accepting_activation:
            self._logger.emit(
                "activation.unavailable",
                route_id=route.route_id,
                trigger_id=wake.trigger_id,
                delegate_health=delegate_status.health,
                detail=delegate_status.detail,
            )
            self._reset_listening()
            return
        self._activate(route, wake, detector_call_ms)

    def _activate(self, route: WakeRoute, wake: WakeEvent, detector_call_ms: float) -> None:
        self._logger.emit(
            "activation.listening",
            route_id=route.route_id,
            trigger_id=wake.trigger_id,
            wake_to_feedback_ms=(time.monotonic_ns() - wake.detected_at_ns) / 1_000_000,
        )
        initial_audio = self._ring.snapshot()
        speech_tail = estimate_speech_tail(initial_audio, self._sample_rate)
        if speech_tail is not None:
            self._logger.emit(
                "wake.speech_tail_estimated",
                route_id=route.route_id,
                estimated_speech_end_to_wake_ms=(
                    speech_tail.trailing_silence_ms + detector_call_ms
                ),
                trailing_silence_ms=speech_tail.trailing_silence_ms,
                speech_rms_threshold=speech_tail.rms_threshold,
            )
        self._conversation.begin()
        self._active_route = route
        try:
            route.delegate.start(
                DelegateStartContext(
                    wake=wake,
                    conversation=self._conversation.handle,
                    sample_rate=self._sample_rate,
                    # Input ownership controls the ongoing stream. The harness
                    # may always provide its bounded wake/preroll snapshot once
                    # so a delegate-owned device can warm or transition without
                    # dropping activation speech.
                    initial_audio=initial_audio,
                    route_id=route.route_id,
                )
            )
        except Exception as error:
            self._logger.emit(
                "activation.error",
                route_id=route.route_id,
                trigger_id=wake.trigger_id,
                detail=str(error),
            )
            self._conversation.finish()
            self._active_route = None
            self._reset_listening()
            raise
        self.state = State.CONVERSATION
        self._logger.emit(
            "orchestrator.state",
            state=self.state,
            route_id=route.route_id,
        )

    def _process_conversation(self, samples: FloatAudio) -> None:
        route = self._active_route
        if route is None:
            raise RuntimeError("conversation state has no active route")
        delegate = route.delegate
        request = self._conversation.take_request()
        if request is not None:
            delegate.request_end(request)
            self.state = State.ENDING
            self._ending_request = request
            self._ending_started_at_ns = time.monotonic_ns()
            self._logger.emit(
                "orchestrator.state",
                state=self.state,
                route_id=route.route_id,
                end_source=request.source,
                end_mode=request.mode,
            )

        if (
            self.state is State.CONVERSATION
            and delegate.capabilities.audio_input is AudioInputOwnership.HARNESS
        ):
            delegate.send_audio(samples, self._sample_rate)
        delegate.poll()
        if not delegate.active:
            self._finish_conversation(route)

    def _finish_conversation(self, route: WakeRoute) -> None:
        if self.state is State.ENDING and self._ending_request is not None:
            self._logger.emit(
                "conversation.ended",
                route_id=route.route_id,
                source=self._ending_request.source,
                reason=self._ending_request.reason,
                mode=self._ending_request.mode,
                ending_ms=(
                    (time.monotonic_ns() - self._ending_started_at_ns) / 1_000_000
                    if self._ending_started_at_ns is not None
                    else 0
                ),
            )
        self._conversation.finish()
        self._active_route = None
        self._ending_request = None
        self._ending_started_at_ns = None
        self.state = State.LISTENING
        self._reset_listening()
        self._logger.emit("orchestrator.state", state=self.state, route_id=route.route_id)

    def _reset_listening(self) -> None:
        self._detector.reset()
        self._ring.clear()


class WakeListener(WakeRouter):
    """One-route convenience API for embedding a single immutable assistant."""

    def __init__(
        self,
        detector: WakeWordEngine,
        delegate: ConversationDelegate,
        logger: EventLogger,
        *,
        sample_rate: int,
        trigger_id: str | None = None,
        route_id: str = "default",
        preroll_seconds: float = 1.0,
        conversation_controller: ConversationController | None = None,
    ) -> None:
        route = (
            WakeRoute.for_trigger(route_id, trigger_id, delegate)
            if trigger_id is not None
            else WakeRoute(route_id, delegate)
        )
        super().__init__(
            detector,
            [route],
            logger,
            sample_rate=sample_rate,
            preroll_seconds=preroll_seconds,
            conversation_controller=conversation_controller,
        )


class Orchestrator(WakeListener):
    """Backward-compatible name for the original catch-all one-route harness."""

    def __init__(
        self,
        detector: WakeWordEngine,
        agent: ConversationDelegate,
        logger: EventLogger,
        *,
        sample_rate: int,
        preroll_seconds: float = 1.0,
        conversation_controller: ConversationController | None = None,
    ) -> None:
        super().__init__(
            detector,
            agent,
            logger,
            sample_rate=sample_rate,
            route_id="default",
            preroll_seconds=preroll_seconds,
            conversation_controller=conversation_controller,
        )
