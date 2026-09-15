from __future__ import annotations

import json
import os
import queue
import shlex
import signal
import subprocess
import threading
import uuid
from collections.abc import Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from typing import Any, Protocol, TextIO

from .events import EventLogger
from .peekaboo_task import ComputerToolEvent, ComputerToolResult

DEFAULT_CODEX_COMMAND = "/Applications/ChatGPT.app/Contents/Resources/codex"


class ProcessFactory(Protocol):
    def __call__(
        self,
        command: Sequence[str],
        **kwargs: Any,
    ) -> subprocess.Popen[str]: ...


@dataclass(slots=True)
class _SkyTask:
    task_id: str
    generation: int
    application: str
    original_goal: str
    cancel_event: threading.Event
    session_id: str | None = None
    pending_steer: str | None = None
    process: subprocess.Popen[str] | None = None
    summary: str = ""
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0


class CodexSkyTaskRunner:
    """Supervise a trusted Codex worker that operates the bundled @oai/sky API."""

    def __init__(
        self,
        logger: EventLogger,
        *,
        allowed_applications: frozenset[str],
        command: Sequence[str] = (DEFAULT_CODEX_COMMAND,),
        model: str = "gpt-5.6-luna",
        cwd: str | None = None,
        process_factory: ProcessFactory = subprocess.Popen,
    ) -> None:
        if not allowed_applications:
            raise ValueError("at least one allowed application is required")
        if not command:
            raise ValueError("Codex command cannot be empty")
        self._logger = logger
        self._allowed_applications = allowed_applications
        self._command = tuple(command)
        self._model = model
        self._cwd = cwd or os.getcwd()
        self._process_factory = process_factory
        self._lock = threading.RLock()
        self._events: queue.SimpleQueue[ComputerToolEvent] = queue.SimpleQueue()
        self._active: _SkyTask | None = None
        self._generation = 0
        self._prepared = False
        self._closed = False
        self._total_input_tokens = 0
        self._total_cached_input_tokens = 0
        self._total_output_tokens = 0

    @property
    def active_task_id(self) -> str | None:
        with self._lock:
            return self._active.task_id if self._active is not None else None

    @property
    def allowed_applications(self) -> tuple[str, ...]:
        return tuple(sorted(self._allowed_applications))

    @property
    def available_tools(self) -> tuple[str, ...]:
        return ("@oai/sky",)

    def prepare(self) -> None:
        with self._lock:
            if self._closed:
                raise RuntimeError("Sky task runner is closed")
            if self._prepared:
                return
            executable = self._command[0]
            if os.path.sep in executable and not os.access(executable, os.X_OK):
                raise RuntimeError(f"Codex executable is not available: {executable}")
            self._prepared = True
        self._logger.emit(
            "computer.runner_ready",
            backend="OAI Sky via Codex",
            tools=["@oai/sky"],
        )

    def start(self, task: str, application: str) -> ComputerToolResult:
        if application not in self._allowed_applications:
            return ComputerToolResult(
                "denied",
                f"{application} is outside the allowed app scope.",
            )
        with self._lock:
            if self._closed:
                raise RuntimeError("Sky task runner is closed")
            if not self._prepared:
                raise RuntimeError("Sky task runner is not prepared")
            if self._active is not None:
                return ComputerToolResult(
                    "busy",
                    "Another computer task is already running.",
                    self._active.task_id,
                )
            self._generation += 1
            active = _SkyTask(
                uuid.uuid4().hex,
                self._generation,
                application,
                task,
                threading.Event(),
            )
            self._active = active
        threading.Thread(
            target=self._run,
            args=(active,),
            name=f"sky-task-{active.task_id}",
            daemon=True,
        ).start()
        return ComputerToolResult("accepted", "Computer task started.", active.task_id)

    def steer(self, task_id: str | None, instruction: str) -> ComputerToolResult:
        instruction = instruction.strip()
        if not instruction:
            return ComputerToolResult("invalid_request", "A new goal is required.", task_id)
        with self._lock:
            active = self._active
            if active is None:
                return ComputerToolResult("not_running", "No computer task is running.")
            if task_id is not None and task_id != active.task_id:
                return ComputerToolResult(
                    "not_found", "That computer task is not active.", task_id
                )
            active.pending_steer = instruction
            process = active.process
        self._stop_process(process)
        self._logger.emit(
            "computer.task_steer_requested",
            task_id=active.task_id,
            generation=active.generation,
        )
        return ComputerToolResult(
            "steering_accepted",
            "The computer task goal is being updated.",
            active.task_id,
        )

    def poll_events(self) -> tuple[ComputerToolEvent, ...]:
        events: list[ComputerToolEvent] = []
        while True:
            try:
                events.append(self._events.get_nowait())
            except queue.Empty:
                return tuple(events)

    def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult:
        with self._lock:
            active = self._active
            if active is None:
                return ComputerToolResult("not_running", "No computer task is running.")
            if task_id is not None and task_id != active.task_id:
                return ComputerToolResult(
                    "not_found", "That computer task is not active.", task_id
                )
            active.cancel_event.set()
            process = active.process
        self._stop_process(process)
        self._logger.emit(
            "computer.task_cancel_requested",
            task_id=active.task_id,
            generation=active.generation,
            reason=reason,
        )
        return ComputerToolResult(
            "cancellation_requested", "Computer task is stopping.", active.task_id
        )

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            active = self._active
            if active is not None:
                active.cancel_event.set()
                process = active.process
            else:
                process = None
        self._stop_process(process)
        self._logger.emit("computer.runner_closed", backend="OAI Sky via Codex")

    def _run(self, active: _SkyTask) -> None:
        self._logger.emit(
            "computer.task_started",
            task_id=active.task_id,
            generation=active.generation,
            application=active.application,
            backend="OAI Sky via Codex",
        )
        prompt = self._initial_prompt(active)
        while not active.cancel_event.is_set():
            command = self._exec_command(active.session_id, prompt)
            try:
                process = self._process_factory(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                    cwd=self._cwd,
                    start_new_session=True,
                )
            except OSError as error:
                self._finish(active, "failed", f"Could not start Codex: {error}")
                return
            with self._lock:
                if self._active is active:
                    active.process = process
            self._drain_stderr(active, process.stderr)
            self._read_events(active, process.stdout)
            returncode = process.wait()
            with self._lock:
                if active.process is process:
                    active.process = None
                steering = active.pending_steer
                active.pending_steer = None
            if active.cancel_event.is_set():
                self._finish(active, "cancelled", "Computer task cancelled.")
                return
            if steering is not None:
                prompt = self._steering_prompt(active, steering)
                continue
            if returncode == 0:
                self._finish(
                    active,
                    "completed",
                    active.summary or "Computer task complete.",
                )
            else:
                self._finish(
                    active,
                    "failed",
                    active.summary or f"Codex exited with status {returncode}.",
                )
            return
        self._finish(active, "cancelled", "Computer task cancelled.")

    def _exec_command(self, session_id: str | None, prompt: str) -> list[str]:
        if session_id is None:
            return [
                *self._command,
                "exec",
                "--json",
                "--approve-for-me",
                "--skip-git-repo-check",
                "-m",
                self._model,
                "-C",
                self._cwd,
                prompt,
            ]
        return [
            *self._command,
            "exec",
            "resume",
            "--json",
            "--skip-git-repo-check",
            "-m",
            self._model,
            session_id,
            prompt,
        ]

    def _read_events(self, active: _SkyTask, stream: TextIO | None) -> None:
        if stream is None:
            return
        for line in stream:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                self._logger.emit(
                    "computer.sky_output",
                    task_id=active.task_id,
                    message=line.rstrip()[:1000],
                )
                continue
            self._handle_event(active, event)

    def _handle_event(self, active: _SkyTask, event: Mapping[str, Any]) -> None:
        event_type = event.get("type")
        if event_type == "thread.started" and isinstance(event.get("thread_id"), str):
            active.session_id = event["thread_id"]
            self._logger.emit(
                "computer.sky_session_started",
                task_id=active.task_id,
                session_id=active.session_id,
            )
            return
        if event_type == "item.completed":
            item = event.get("item")
            if isinstance(item, Mapping) and item.get("type") == "agent_message":
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    active.summary = text.strip()[:2000]
            return
        if event_type != "turn.completed":
            return
        usage = event.get("usage")
        if not isinstance(usage, Mapping):
            return
        input_tokens = self._integer(usage.get("input_tokens"))
        cached_tokens = self._integer(usage.get("cached_input_tokens"))
        output_tokens = self._integer(usage.get("output_tokens"))
        active.input_tokens += input_tokens
        active.cached_input_tokens += cached_tokens
        active.output_tokens += output_tokens
        with self._lock:
            self._total_input_tokens += input_tokens
            self._total_cached_input_tokens += cached_tokens
            self._total_output_tokens += output_tokens
            totals = (
                self._total_input_tokens,
                self._total_cached_input_tokens,
                self._total_output_tokens,
            )
        self._logger.emit(
            "computer.sky_usage",
            task_id=active.task_id,
            model=self._model,
            input_tokens=active.input_tokens,
            cached_input_tokens=active.cached_input_tokens,
            uncached_input_tokens=max(0, active.input_tokens - active.cached_input_tokens),
            output_tokens=active.output_tokens,
            total_input_tokens=totals[0],
            total_cached_input_tokens=totals[1],
            total_output_tokens=totals[2],
        )

    def _drain_stderr(self, active: _SkyTask, stream: TextIO | None) -> None:
        if stream is None:
            return

        def drain() -> None:
            for line in stream:
                message = line.strip()
                if message:
                    self._logger.emit(
                        "computer.sky_stderr",
                        task_id=active.task_id,
                        message=message[:1000],
                    )

        threading.Thread(target=drain, name="sky-stderr", daemon=True).start()

    def _finish(self, active: _SkyTask, status: str, summary: str) -> None:
        with self._lock:
            if self._active is not active:
                return
            self._active = None
        self._events.put(
            ComputerToolEvent(
                active.task_id,
                active.generation,
                status,
                summary[:2000],
                True,
            )
        )
        self._logger.emit(
            "computer.task_finished",
            task_id=active.task_id,
            generation=active.generation,
            status=status,
            input_tokens=active.input_tokens,
            cached_input_tokens=active.cached_input_tokens,
            output_tokens=active.output_tokens,
        )

    def _initial_prompt(self, active: _SkyTask) -> str:
        allowed = ", ".join(sorted(self._allowed_applications))
        return (
            "Use the installed $computer-use skill and its @oai/sky API through node_repl. "
            "Do not use Chrome/browser plugins, shell UI automation, AppleScript, or another "
            "computer-use backend. Keep the current app and window unless the user explicitly "
            "requests a new one. Prefer accessibility text and element indices; observe before "
            "acting and verify the final state. Keep model commentary minimal. "
            f"Operate only in {active.application!r}; allowed applications: {allowed}. "
            f"User task: {active.original_goal}"
        )

    @staticmethod
    def _steering_prompt(active: _SkyTask, instruction: str) -> str:
        return (
            "The user changed the active computer task. Stop pursuing the prior goal, preserve "
            f"useful UI state, continue only in {active.application!r}, and follow this revised "
            f"instruction: {instruction}"
        )

    @staticmethod
    def _stop_process(process: subprocess.Popen[str] | None) -> None:
        if process is None or process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            with suppress(OSError):
                process.terminate()

    @staticmethod
    def _integer(value: Any) -> int:
        return value if isinstance(value, int) and value >= 0 else 0


def parse_codex_command(value: str) -> tuple[str, ...]:
    command = tuple(shlex.split(value))
    if not command:
        raise ValueError("Codex command cannot be empty")
    return command
