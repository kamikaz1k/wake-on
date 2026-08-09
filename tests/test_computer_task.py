from __future__ import annotations

import io
import threading
import time
from collections.abc import Sequence

from lobby_wake.computer_task import (
    CompleteComputerTask,
    ComputerAction,
    ComputerActionKind,
    ComputerActionResult,
    ComputerActionRisk,
    ComputerObservation,
    ComputerPolicyScope,
    ComputerTaskEventKind,
    ComputerTaskRequest,
    ComputerTaskState,
    ComputerTaskWorker,
    PlannedComputerAction,
    PlannerDecision,
    StaleObservationError,
)
from lobby_wake.events import EventLogger


class ScriptedPlanner:
    def __init__(self, decisions: Sequence[PlannerDecision]) -> None:
        self.decisions = list(decisions)
        self.calls: list[tuple[ComputerObservation, tuple[ComputerActionResult, ...]]] = []

    def next_step(
        self,
        request: ComputerTaskRequest,
        observation: ComputerObservation,
        history: tuple[ComputerActionResult, ...],
    ) -> PlannerDecision:
        del request
        self.calls.append((observation, history))
        if not self.decisions:
            raise RuntimeError("scripted planner ran out of decisions")
        return self.decisions.pop(0)


class FakeComputerExecutor:
    def __init__(
        self,
        *,
        block_actions: bool = False,
        fail_observation: bool = False,
        stale_once: bool = False,
    ) -> None:
        self.revision = 1
        self.prepare_count = 0
        self.close_count = 0
        self.observations: list[str] = []
        self.actions: list[ComputerAction] = []
        self.cancel_calls: list[tuple[str, int]] = []
        self.block_actions = block_actions
        self.fail_observation = fail_observation
        self.stale_once = stale_once
        self.action_started = threading.Event()
        self.release_action = threading.Event()

    def prepare(self) -> None:
        self.prepare_count += 1

    def observe(self, application: str) -> ComputerObservation:
        if self.fail_observation:
            raise RuntimeError("fixture observation failed")
        self.observations.append(application)
        return ComputerObservation(
            application=application,
            revision=str(self.revision),
            accessibility_text=f"fixture revision {self.revision}",
        )

    def act(
        self,
        revision: str,
        action: ComputerAction,
        cancel_event: threading.Event,
    ) -> ComputerActionResult:
        del cancel_event
        self.action_started.set()
        if self.block_actions:
            self.release_action.wait(2)
        if self.stale_once:
            self.stale_once = False
            self.revision += 1
            raise StaleObservationError("fixture changed")
        if revision != str(self.revision):
            raise StaleObservationError("fixture changed")
        self.actions.append(action)
        self.revision += 1
        return ComputerActionResult(action.action_id, True, str(self.revision))

    def cancel(self, task_id: str, generation: int) -> None:
        self.cancel_calls.append((task_id, generation))
        self.release_action.set()

    def close(self) -> None:
        self.close_count += 1

    def mutate(self) -> None:
        self.revision += 1


def make_action(
    action_id: str = "action-1",
    *,
    kind: ComputerActionKind = ComputerActionKind.TYPE_TEXT,
    application: str = "TextEdit",
) -> ComputerAction:
    return ComputerAction(
        action_id=action_id,
        kind=kind,
        application=application,
        description="Type the fixture text",
        risk=ComputerActionRisk.REVERSIBLE,
        parameters={"text": "WakeOn fixture"},
    )


def make_request(
    *,
    task_id: str = "task-1",
    generation: int = 7,
    allowed_actions: frozenset[ComputerActionKind] | None = None,
    approval_actions: frozenset[ComputerActionKind] = frozenset(),
) -> ComputerTaskRequest:
    return ComputerTaskRequest(
        task_id=task_id,
        generation=generation,
        user_intent="Create the deterministic TextEdit fixture",
        target_application="TextEdit",
        policy_scope=ComputerPolicyScope(
            allowed_applications=frozenset({"TextEdit"}),
            allowed_actions=allowed_actions
            or frozenset({ComputerActionKind.OBSERVE, ComputerActionKind.TYPE_TEXT}),
            approval_actions=approval_actions,
        ),
    )


def prepared_worker(
    planner: ScriptedPlanner,
    executor: FakeComputerExecutor,
) -> tuple[ComputerTaskWorker, EventLogger]:
    logger = EventLogger(stream=io.StringIO())
    worker = ComputerTaskWorker(logger, planner, executor)
    worker.prepare()
    return worker, logger


def wait_for_state(
    worker: ComputerTaskWorker,
    expected: ComputerTaskState,
    *,
    timeout: float = 1,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if worker.status.state is expected:
            return
        time.sleep(0.005)
    raise AssertionError(f"worker did not reach {expected}; current={worker.status.state}")


def test_worker_runs_action_and_completes_with_progress() -> None:
    action = make_action()
    planner = ScriptedPlanner(
        [PlannedComputerAction(action), CompleteComputerTask("Fixture created.")]
    )
    executor = FakeComputerExecutor()
    worker, logger = prepared_worker(planner, executor)

    worker.start(make_request())
    assert worker.wait(1)

    events = worker.poll_events()
    assert worker.status.state is ComputerTaskState.COMPLETED
    assert executor.actions == [action]
    assert [event.kind for event in events] == [
        ComputerTaskEventKind.STARTED,
        ComputerTaskEventKind.PROGRESS,
        ComputerTaskEventKind.COMPLETED,
    ]
    assert events[-1].summary == "Fixture created."
    worker.close()
    logger.close()


def test_policy_denies_disallowed_application_before_observation() -> None:
    planner = ScriptedPlanner([CompleteComputerTask("Should not run")])
    executor = FakeComputerExecutor()
    worker, logger = prepared_worker(planner, executor)
    request = make_request()
    request = ComputerTaskRequest(
        request.task_id,
        request.generation,
        request.user_intent,
        "Safari",
        request.policy_scope,
    )

    worker.start(request)
    assert worker.wait(1)

    events = worker.poll_events()
    assert worker.status.state is ComputerTaskState.FAILED
    assert executor.observations == []
    assert events[-1].error_code == "policy_denied"
    worker.close()
    logger.close()


def test_approval_reobserves_then_executes_when_revision_is_fresh() -> None:
    action = make_action()
    planner = ScriptedPlanner(
        [PlannedComputerAction(action), CompleteComputerTask("Approved fixture created.")]
    )
    executor = FakeComputerExecutor()
    worker, logger = prepared_worker(planner, executor)
    request = make_request(approval_actions=frozenset({ComputerActionKind.TYPE_TEXT}))

    worker.start(request)
    wait_for_state(worker, ComputerTaskState.AWAITING_APPROVAL)
    approval_id = worker.status.approval_id
    assert approval_id is not None
    approval_event = next(
        event
        for event in worker.poll_events()
        if event.kind is ComputerTaskEventKind.APPROVAL_REQUIRED
    )
    assert approval_event.action is not None
    assert approval_event.action.risk is ComputerActionRisk.REVERSIBLE
    assert approval_event.approval_expires_at_ns is not None
    assert approval_event.approval_expires_at_ns > time.monotonic_ns()
    assert not worker.approve(request.task_id, request.generation, "wrong-id")
    assert worker.approve(request.task_id, request.generation, approval_id)
    assert worker.wait(1)

    assert worker.status.state is ComputerTaskState.COMPLETED
    assert executor.actions == [action]
    assert executor.observations == ["TextEdit", "TextEdit", "TextEdit"]
    worker.close()
    logger.close()


def test_changed_ui_during_approval_is_replanned_without_acting() -> None:
    action = make_action()
    planner = ScriptedPlanner(
        [PlannedComputerAction(action), CompleteComputerTask("UI changed; no action taken.")]
    )
    executor = FakeComputerExecutor()
    worker, logger = prepared_worker(planner, executor)
    request = make_request(approval_actions=frozenset({ComputerActionKind.TYPE_TEXT}))

    worker.start(request)
    wait_for_state(worker, ComputerTaskState.AWAITING_APPROVAL)
    approval_id = worker.status.approval_id
    assert approval_id is not None
    executor.mutate()
    assert worker.approve(request.task_id, request.generation, approval_id)
    assert worker.wait(1)

    assert executor.actions == []
    assert planner.calls[1][1][-1].detail == "stale_observation"
    assert any(event.phase == "reobserving" for event in worker.poll_events())
    worker.close()
    logger.close()


def test_executor_stale_revision_is_reobserved_and_replanned() -> None:
    action = make_action()
    planner = ScriptedPlanner(
        [PlannedComputerAction(action), CompleteComputerTask("Replanned safely.")]
    )
    executor = FakeComputerExecutor(stale_once=True)
    worker, logger = prepared_worker(planner, executor)

    worker.start(make_request())
    assert worker.wait(1)

    assert executor.actions == []
    assert planner.calls[1][1][-1].detail == "stale_observation"
    assert worker.status.state is ComputerTaskState.COMPLETED
    worker.close()
    logger.close()


def test_rejected_approval_cancels_task_without_action() -> None:
    action = make_action()
    planner = ScriptedPlanner([PlannedComputerAction(action)])
    executor = FakeComputerExecutor()
    worker, logger = prepared_worker(planner, executor)
    request = make_request(approval_actions=frozenset({ComputerActionKind.TYPE_TEXT}))

    worker.start(request)
    wait_for_state(worker, ComputerTaskState.AWAITING_APPROVAL)
    approval_id = worker.status.approval_id
    assert approval_id is not None
    assert worker.reject(request.task_id, request.generation, approval_id)
    assert worker.wait(1)

    assert worker.status.state is ComputerTaskState.CANCELLED
    assert executor.actions == []
    assert worker.poll_events()[-1].summary == "approval_rejected"
    worker.close()
    logger.close()


def test_approval_expires_without_executing_action() -> None:
    action = make_action()
    planner = ScriptedPlanner([PlannedComputerAction(action)])
    executor = FakeComputerExecutor()
    logger = EventLogger(stream=io.StringIO())
    worker = ComputerTaskWorker(
        logger,
        planner,
        executor,
        approval_timeout_seconds=0.02,
    )
    worker.prepare()
    request = make_request(approval_actions=frozenset({ComputerActionKind.TYPE_TEXT}))

    worker.start(request)
    assert worker.wait(1)

    assert worker.status.state is ComputerTaskState.CANCELLED
    assert executor.actions == []
    assert worker.poll_events()[-1].summary == "approval_timeout"
    worker.close()
    logger.close()


def test_generation_scoped_cancel_dominates_late_action_result() -> None:
    action = make_action()
    planner = ScriptedPlanner(
        [PlannedComputerAction(action), CompleteComputerTask("Late completion")]
    )
    executor = FakeComputerExecutor(block_actions=True)
    worker, logger = prepared_worker(planner, executor)
    request = make_request()

    worker.start(request)
    assert executor.action_started.wait(1)
    assert not worker.cancel(request.task_id, request.generation + 1, reason="stale")
    assert worker.cancel(request.task_id, request.generation, reason="emergency_stop")
    assert worker.wait(1)

    events = worker.poll_events()
    assert worker.status.state is ComputerTaskState.CANCELLED
    assert executor.cancel_calls == [(request.task_id, request.generation)]
    assert not any(event.kind is ComputerTaskEventKind.COMPLETED for event in events)
    assert not any(event.phase == "action_completed" for event in events)
    worker.close()
    logger.close()


def test_worker_failure_is_reported_without_screen_content_in_logs() -> None:
    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    planner = ScriptedPlanner([CompleteComputerTask("not reached")])
    executor = FakeComputerExecutor(fail_observation=True)
    worker = ComputerTaskWorker(logger, planner, executor)
    worker.prepare()

    worker.start(make_request())
    assert worker.wait(1)

    events = worker.poll_events()
    assert worker.status.state is ComputerTaskState.FAILED
    assert events[-1].error_code == "worker_error"
    assert "fixture observation failed" in (events[-1].summary or "")
    assert "fixture observation failed" not in stream.getvalue()
    worker.close()
    logger.close()
