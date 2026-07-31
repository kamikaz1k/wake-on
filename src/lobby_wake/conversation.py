from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from enum import StrEnum

from .events import EventLogger


class EndMode(StrEnum):
    GRACEFUL = "graceful"
    IMMEDIATE = "immediate"


class EndSource(StrEnum):
    MODEL = "model"
    DELEGATE = "delegate"
    USER = "user"
    TIMEOUT = "timeout"
    SYSTEM = "system"


@dataclass(frozen=True, slots=True)
class EndConversationRequest:
    source: EndSource
    reason: str
    mode: EndMode
    requested_at_ns: int
    farewell: str | None = None
    tool_call_id: str | None = None


class ConversationHandle:
    """Restricted lifecycle capability passed to a long-running delegate."""

    def __init__(self, controller: ConversationController, generation: int) -> None:
        self._controller = controller
        self._generation = generation

    def end(
        self,
        *,
        reason: str = "task_complete",
        farewell: str | None = None,
        immediate: bool = False,
    ) -> bool:
        return self._controller.request_end(
            source=EndSource.DELEGATE,
            reason=reason,
            mode=EndMode.IMMEDIATE if immediate else EndMode.GRACEFUL,
            farewell=farewell,
            generation=self._generation,
        )

    def kill(self, *, reason: str = "emergency_stop") -> bool:
        return self.end(reason=reason, immediate=True)


class ConversationController:
    """Owns one active conversation and serializes its end requests."""

    def __init__(self, logger: EventLogger) -> None:
        self._logger = logger
        self._lock = threading.Lock()
        self._active = False
        self._pending: EndConversationRequest | None = None
        self._generation = 0
        self._handle = ConversationHandle(self, self._generation)

    @property
    def handle(self) -> ConversationHandle:
        with self._lock:
            return self._handle

    @property
    def active(self) -> bool:
        with self._lock:
            return self._active

    def begin(self) -> None:
        with self._lock:
            self._generation += 1
            self._active = True
            self._pending = None
            self._handle = ConversationHandle(self, self._generation)

    def finish(self) -> None:
        with self._lock:
            self._active = False
            self._pending = None

    def request_end(
        self,
        *,
        source: EndSource,
        reason: str,
        mode: EndMode,
        farewell: str | None = None,
        tool_call_id: str | None = None,
        generation: int | None = None,
    ) -> bool:
        request = EndConversationRequest(
            source=source,
            reason=reason,
            mode=mode,
            requested_at_ns=time.monotonic_ns(),
            farewell=farewell,
            tool_call_id=tool_call_id,
        )
        with self._lock:
            if (generation is not None and generation != self._generation) or not self._active:
                accepted = False
            elif self._pending is None or (
                self._pending.mode is EndMode.GRACEFUL and mode is EndMode.IMMEDIATE
            ):
                self._pending = request
                accepted = True
            else:
                accepted = False

        self._logger.emit(
            "conversation.end_requested" if accepted else "conversation.end_ignored",
            source=source,
            reason=reason,
            mode=mode,
        )
        return accepted

    def take_request(self) -> EndConversationRequest | None:
        with self._lock:
            request = self._pending
            self._pending = None
            return request
