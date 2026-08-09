from __future__ import annotations

import queue
import threading
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType
from typing import Any, Protocol, TypeAlias

from .events import EventLogger


class ComputerActionKind(StrEnum):
    OBSERVE = "observe"
    CLICK = "click"
    TYPE_TEXT = "type_text"
    SET_VALUE = "set_value"
    PRESS_KEY = "press_key"
    SCROLL = "scroll"
    PERFORM_ACTION = "perform_action"
    LAUNCH_APP = "launch_app"
    FOCUS_WINDOW = "focus_window"


class ComputerTaskState(StrEnum):
    CREATED = "created"
    READY = "ready"
    RUNNING = "running"
    AWAITING_APPROVAL = "awaiting_approval"
    CANCELLING = "cancelling"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    CLOSED = "closed"


class ComputerTaskEventKind(StrEnum):
    STARTED = "started"
    PROGRESS = "progress"
    APPROVAL_REQUIRED = "approval_required"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class ComputerActionRisk(StrEnum):
    READ_ONLY = "read_only"
    REVERSIBLE = "reversible"
    CONSEQUENTIAL = "consequential"
    SENSITIVE = "sensitive"


@dataclass(frozen=True, slots=True)
class ComputerPolicyScope:
    allowed_applications: frozenset[str]
    allowed_actions: frozenset[ComputerActionKind]
    approval_actions: frozenset[ComputerActionKind] = frozenset()

    def __post_init__(self) -> None:
        if not self.allowed_applications:
            raise ValueError("computer policy requires at least one allowed application")
        if ComputerActionKind.OBSERVE not in self.allowed_actions:
            raise ValueError("computer policy must allow observation")
        if not self.approval_actions.issubset(self.allowed_actions):
            raise ValueError("approval actions must also be allowed")

    def allows(self, action: ComputerAction) -> bool:
        return (
            action.application in self.allowed_applications
            and action.kind in self.allowed_actions
        )

    def requires_approval(self, action: ComputerAction) -> bool:
        return action.kind in self.approval_actions


@dataclass(frozen=True, slots=True)
class ComputerTaskRequest:
    task_id: str
    generation: int
    user_intent: str
    target_application: str
    policy_scope: ComputerPolicyScope

    def __post_init__(self) -> None:
        if not self.task_id.strip():
            raise ValueError("computer task ID cannot be empty")
        if self.generation < 0:
            raise ValueError("computer task generation cannot be negative")
        if not self.user_intent.strip():
            raise ValueError("computer task intent cannot be empty")
        if not self.target_application.strip():
            raise ValueError("computer task target application cannot be empty")


@dataclass(frozen=True, slots=True)
class ComputerObservation:
    application: str
    revision: str
    accessibility_text: str = ""
    screenshot: Path | None = None

    def __post_init__(self) -> None:
        if not self.application.strip() or not self.revision.strip():
            raise ValueError("computer observations require application and revision")


@dataclass(frozen=True, slots=True)
class ComputerAction:
    action_id: str
    kind: ComputerActionKind
    application: str
    description: str
    risk: ComputerActionRisk
    parameters: Mapping[str, Any]

    def __post_init__(self) -> None:
        if not self.action_id.strip():
            raise ValueError("computer action ID cannot be empty")
        if not self.application.strip() or not self.description.strip():
            raise ValueError("computer actions require application and description")
        object.__setattr__(self, "parameters", MappingProxyType(dict(self.parameters)))


@dataclass(frozen=True, slots=True)
class ComputerActionResult:
    action_id: str
    accepted: bool
    revision: str
    detail: str | None = None


@dataclass(frozen=True, slots=True)
class PlannedComputerAction:
    action: ComputerAction


@dataclass(frozen=True, slots=True)
class CompleteComputerTask:
    summary: str


PlannerDecision: TypeAlias = PlannedComputerAction | CompleteComputerTask


class ComputerTaskPlanner(Protocol):
    def next_step(
        self,
        request: ComputerTaskRequest,
        observation: ComputerObservation,
        history: tuple[ComputerActionResult, ...],
    ) -> PlannerDecision: ...


class ComputerExecutor(Protocol):
    def prepare(self) -> None: ...

    def observe(self, application: str) -> ComputerObservation: ...

    def act(
        self,
        revision: str,
        action: ComputerAction,
        cancel_event: threading.Event,
    ) -> ComputerActionResult: ...

    def cancel(self, task_id: str, generation: int) -> None: ...

    def close(self) -> None: ...


class StaleObservationError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ComputerTaskStatus:
    state: ComputerTaskState
    task_id: str | None = None
    generation: int | None = None
    approval_id: str | None = None


@dataclass(frozen=True, slots=True)
class ComputerTaskEvent:
    kind: ComputerTaskEventKind
    task_id: str
    generation: int
    occurred_at_ns: int
    phase: str | None = None
    summary: str | None = None
    approval_id: str | None = None
    approval_expires_at_ns: int | None = None
    action: ComputerAction | None = None
    error_code: str | None = None


class ComputerTaskService(Protocol):
    @property
    def status(self) -> ComputerTaskStatus: ...

    def prepare(self) -> None: ...

    def start(self, request: ComputerTaskRequest) -> None: ...

    def approve(self, task_id: str, generation: int, approval_id: str) -> bool: ...

    def reject(self, task_id: str, generation: int, approval_id: str) -> bool: ...

    def cancel(self, task_id: str, generation: int, *, reason: str) -> bool: ...

    def poll_events(self) -> tuple[ComputerTaskEvent, ...]: ...

    def close(self) -> None: ...


class ComputerTaskWorker:
    """Runs one generation-scoped computer task behind a narrow local contract."""

    def __init__(
        self,
        logger: EventLogger,
        planner: ComputerTaskPlanner,
        executor: ComputerExecutor,
        *,
        max_steps: int = 20,
        approval_timeout_seconds: float = 60.0,
    ) -> None:
        if max_steps <= 0:
            raise ValueError("computer task max steps must be positive")
        if approval_timeout_seconds <= 0:
            raise ValueError("computer task approval timeout must be positive")
        self._logger = logger
        self._planner = planner
        self._executor = executor
        self._max_steps = max_steps
        self._approval_timeout_ns = round(approval_timeout_seconds * 1_000_000_000)
        self._lock = threading.RLock()
        self._approval_changed = threading.Condition(self._lock)
        self._events: queue.Queue[ComputerTaskEvent] = queue.Queue()
        self._state = ComputerTaskState.CREATED
        self._request: ComputerTaskRequest | None = None
        self._approval_id: str | None = None
        self._approval_decision: bool | None = None
        self._cancel_reason: str | None = None
        self._cancel_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._prepared = False
        self._closed = False

    @property
    def status(self) -> ComputerTaskStatus:
        with self._lock:
            request = self._request
            return ComputerTaskStatus(
                self._state,
                request.task_id if request is not None else None,
                request.generation if request is not None else None,
                self._approval_id,
            )

    def prepare(self) -> None:
        with self._lock:
            if self._closed or self._prepared:
                return
        self._executor.prepare()
        with self._lock:
            if self._closed:
                self._executor.close()
                return
            self._prepared = True
            self._state = ComputerTaskState.READY
        self._logger.emit("computer.worker_ready")

    def start(self, request: ComputerTaskRequest) -> None:
        with self._lock:
            if self._closed:
                raise RuntimeError("computer task worker is closed")
            if not self._prepared:
                raise RuntimeError("computer task worker is not prepared")
            if self._thread is not None and self._thread.is_alive():
                raise RuntimeError("computer task worker already has an active task")
            self._request = request
            self._approval_id = None
            self._approval_decision = None
            self._cancel_reason = None
            self._cancel_event = threading.Event()
            self._state = ComputerTaskState.RUNNING
            self._thread = threading.Thread(
                target=self._run,
                args=(request,),
                name=f"computer-task-{request.task_id}",
                daemon=True,
            )
            thread = self._thread
        thread.start()

    def approve(self, task_id: str, generation: int, approval_id: str) -> bool:
        return self._resolve_approval(task_id, generation, approval_id, approved=True)

    def reject(self, task_id: str, generation: int, approval_id: str) -> bool:
        return self._resolve_approval(task_id, generation, approval_id, approved=False)

    def cancel(self, task_id: str, generation: int, *, reason: str) -> bool:
        with self._lock:
            request = self._request
            if (
                request is None
                or request.task_id != task_id
                or request.generation != generation
                or self._state
                in {
                    ComputerTaskState.COMPLETED,
                    ComputerTaskState.FAILED,
                    ComputerTaskState.CANCELLED,
                    ComputerTaskState.CLOSED,
                }
            ):
                accepted = False
            else:
                self._cancel_reason = reason
                self._cancel_event.set()
                self._state = ComputerTaskState.CANCELLING
                self._approval_changed.notify_all()
                accepted = True
        if accepted:
            try:
                self._executor.cancel(task_id, generation)
            except Exception as error:  # Cancellation remains dominant.
                self._logger.emit(
                    "computer.executor_cancel_error",
                    task_id=task_id,
                    generation=generation,
                    detail=str(error),
                )
            self._logger.emit(
                "computer.task_cancel_requested",
                task_id=task_id,
                generation=generation,
                reason=reason,
            )
        return accepted

    def poll_events(self) -> tuple[ComputerTaskEvent, ...]:
        events: list[ComputerTaskEvent] = []
        while True:
            try:
                events.append(self._events.get_nowait())
            except queue.Empty:
                return tuple(events)

    def wait(self, timeout: float | None = None) -> bool:
        with self._lock:
            thread = self._thread
        if thread is None:
            return True
        thread.join(timeout)
        return not thread.is_alive()

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            request = self._request
            active = self._state in {
                ComputerTaskState.RUNNING,
                ComputerTaskState.AWAITING_APPROVAL,
                ComputerTaskState.CANCELLING,
            }
        if active and request is not None:
            self.cancel(request.task_id, request.generation, reason="worker_closed")
        self.wait(2)
        self._executor.close()
        with self._lock:
            self._state = ComputerTaskState.CLOSED
            self._prepared = False
        self._logger.emit("computer.worker_closed")

    def _run(self, request: ComputerTaskRequest) -> None:
        self._emit(ComputerTaskEventKind.STARTED, request, phase="starting")
        self._logger.emit(
            "computer.task_started",
            task_id=request.task_id,
            generation=request.generation,
            application=request.target_application,
        )
        history: list[ComputerActionResult] = []
        try:
            if (
                request.target_application not in request.policy_scope.allowed_applications
                or ComputerActionKind.OBSERVE not in request.policy_scope.allowed_actions
            ):
                self._finish_failed(
                    request,
                    "policy_denied",
                    "The target application is outside the allowed observation scope.",
                )
                return
            observation = self._executor.observe(request.target_application)
            for _step in range(self._max_steps):
                if self._finish_if_cancelled(request):
                    return
                decision = self._planner.next_step(request, observation, tuple(history))
                if isinstance(decision, CompleteComputerTask):
                    if self._finish_if_cancelled(request):
                        return
                    self._finish_completed(request, decision.summary)
                    return

                action = decision.action
                if not request.policy_scope.allows(action):
                    self._finish_failed(
                        request,
                        "policy_denied",
                        "The requested computer action is outside the allowed scope.",
                    )
                    return

                planned_revision = observation.revision
                if request.policy_scope.requires_approval(action):
                    approval = self._wait_for_approval(request, action)
                    if approval is None:
                        self._finish_cancelled(request)
                        return
                    if not approval:
                        self._cancel_reason = "approval_rejected"
                        self._finish_cancelled(request)
                        return
                    fresh_observation = self._executor.observe(action.application)
                    if fresh_observation.revision != planned_revision:
                        result = ComputerActionResult(
                            action.action_id,
                            False,
                            fresh_observation.revision,
                            "stale_observation",
                        )
                        history.append(result)
                        observation = fresh_observation
                        self._emit(
                            ComputerTaskEventKind.PROGRESS,
                            request,
                            phase="reobserving",
                            summary="The interface changed while approval was pending.",
                        )
                        continue
                    observation = fresh_observation

                if self._finish_if_cancelled(request):
                    return
                self._set_state(ComputerTaskState.RUNNING)
                try:
                    result = self._executor.act(
                        observation.revision,
                        action,
                        self._cancel_event,
                    )
                except StaleObservationError:
                    observation = self._executor.observe(action.application)
                    history.append(
                        ComputerActionResult(
                            action.action_id,
                            False,
                            observation.revision,
                            "stale_observation",
                        )
                    )
                    self._emit(
                        ComputerTaskEventKind.PROGRESS,
                        request,
                        phase="reobserving",
                        summary="The interface changed before the action could run.",
                    )
                    continue

                if self._finish_if_cancelled(request):
                    return
                history.append(result)
                self._emit(
                    ComputerTaskEventKind.PROGRESS,
                    request,
                    phase="action_completed",
                    summary=action.description,
                    action=action,
                )
                self._logger.emit(
                    "computer.action_completed",
                    task_id=request.task_id,
                    generation=request.generation,
                    action_id=action.action_id,
                    action_kind=action.kind,
                    application=action.application,
                    accepted=result.accepted,
                )
                observation = self._executor.observe(action.application)
        except Exception as error:
            if self._finish_if_cancelled(request):
                return
            self._finish_failed(request, "worker_error", str(error))
            return
        self._finish_failed(
            request,
            "step_limit",
            f"Computer task exceeded its {self._max_steps}-step limit.",
        )

    def _wait_for_approval(
        self,
        request: ComputerTaskRequest,
        action: ComputerAction,
    ) -> bool | None:
        approval_id = uuid.uuid4().hex
        approval_expires_at_ns = time.monotonic_ns() + self._approval_timeout_ns
        with self._approval_changed:
            self._approval_id = approval_id
            self._approval_decision = None
            self._state = ComputerTaskState.AWAITING_APPROVAL
        self._emit(
            ComputerTaskEventKind.APPROVAL_REQUIRED,
            request,
            phase="awaiting_approval",
            summary=action.description,
            approval_id=approval_id,
            approval_expires_at_ns=approval_expires_at_ns,
            action=action,
        )
        self._logger.emit(
            "computer.approval_required",
            task_id=request.task_id,
            generation=request.generation,
            approval_id=approval_id,
            action_id=action.action_id,
            action_kind=action.kind,
            application=action.application,
        )
        with self._approval_changed:
            while self._approval_decision is None and not self._cancel_event.is_set():
                remaining_ns = approval_expires_at_ns - time.monotonic_ns()
                if remaining_ns <= 0:
                    self._cancel_reason = "approval_timeout"
                    break
                self._approval_changed.wait(remaining_ns / 1_000_000_000)
            decision = self._approval_decision
            self._approval_id = None
            self._approval_decision = None
            return decision

    def _resolve_approval(
        self,
        task_id: str,
        generation: int,
        approval_id: str,
        *,
        approved: bool,
    ) -> bool:
        with self._approval_changed:
            request = self._request
            if (
                request is None
                or request.task_id != task_id
                or request.generation != generation
                or self._state is not ComputerTaskState.AWAITING_APPROVAL
                or self._approval_id != approval_id
            ):
                return False
            self._approval_decision = approved
            self._approval_changed.notify_all()
            return True

    def _finish_if_cancelled(self, request: ComputerTaskRequest) -> bool:
        if not self._cancel_event.is_set():
            return False
        self._finish_cancelled(request)
        return True

    def _finish_completed(self, request: ComputerTaskRequest, summary: str) -> None:
        self._set_state(ComputerTaskState.COMPLETED)
        self._emit(ComputerTaskEventKind.COMPLETED, request, summary=summary)
        self._logger.emit(
            "computer.task_completed",
            task_id=request.task_id,
            generation=request.generation,
        )

    def _finish_failed(
        self,
        request: ComputerTaskRequest,
        error_code: str,
        summary: str,
    ) -> None:
        self._set_state(ComputerTaskState.FAILED)
        self._emit(
            ComputerTaskEventKind.FAILED,
            request,
            summary=summary,
            error_code=error_code,
        )
        self._logger.emit(
            "computer.task_failed",
            task_id=request.task_id,
            generation=request.generation,
            error_code=error_code,
        )

    def _finish_cancelled(self, request: ComputerTaskRequest) -> None:
        reason = self._cancel_reason or "cancelled"
        self._set_state(ComputerTaskState.CANCELLED)
        self._emit(ComputerTaskEventKind.CANCELLED, request, summary=reason)
        self._logger.emit(
            "computer.task_cancelled",
            task_id=request.task_id,
            generation=request.generation,
            reason=reason,
        )

    def _set_state(self, state: ComputerTaskState) -> None:
        with self._lock:
            self._state = state

    def _emit(
        self,
        kind: ComputerTaskEventKind,
        request: ComputerTaskRequest,
        *,
        phase: str | None = None,
        summary: str | None = None,
        approval_id: str | None = None,
        approval_expires_at_ns: int | None = None,
        action: ComputerAction | None = None,
        error_code: str | None = None,
    ) -> None:
        self._events.put(
            ComputerTaskEvent(
                kind,
                request.task_id,
                request.generation,
                time.monotonic_ns(),
                phase,
                summary,
                approval_id,
                approval_expires_at_ns,
                action,
                error_code,
            )
        )
