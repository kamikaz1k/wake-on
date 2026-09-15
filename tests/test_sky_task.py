from __future__ import annotations

import io
import json
import time
from collections.abc import Sequence
from typing import Any

from lobby_wake.events import EventLogger
from lobby_wake.sky_task import CodexSkyTaskRunner


class FakeProcess:
    next_pid = 9000

    def __init__(self, events: list[dict[str, Any]], returncode: int = 0) -> None:
        self.pid = FakeProcess.next_pid
        FakeProcess.next_pid += 1
        self.stdout = io.StringIO("".join(json.dumps(event) + "\n" for event in events))
        self.stderr = io.StringIO("")
        self._returncode = returncode
        self.terminated = False

    def wait(self) -> int:
        return self._returncode

    def poll(self) -> int | None:
        return self._returncode if self.terminated else None

    def terminate(self) -> None:
        self.terminated = True


class FakeProcessFactory:
    def __init__(self, batches: list[list[dict[str, Any]]]) -> None:
        self.batches = batches
        self.commands: list[list[str]] = []

    def __call__(self, command: Sequence[str], **kwargs: Any) -> FakeProcess:
        self.commands.append(list(command))
        return FakeProcess(self.batches.pop(0))


def _terminal(runner: CodexSkyTaskRunner) -> Any:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        event = next((item for item in runner.poll_events() if item.terminal), None)
        if event is not None:
            return event
        time.sleep(0.01)
    raise AssertionError("task did not finish")


def test_sky_runner_supervises_codex_and_records_usage() -> None:
    factory = FakeProcessFactory(
        [
            [
                {"type": "thread.started", "thread_id": "sky-session"},
                {
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "Chrome is ready."},
                },
                {
                    "type": "turn.completed",
                    "usage": {
                        "input_tokens": 120,
                        "cached_input_tokens": 80,
                        "output_tokens": 10,
                    },
                },
            ]
        ]
    )
    stream = io.StringIO()
    logger = EventLogger(stream=stream)
    runner = CodexSkyTaskRunner(
        logger,
        allowed_applications=frozenset({"Google Chrome"}),
        command=("codex-fixture",),
        process_factory=factory,
    )
    runner.prepare()
    accepted = runner.start("Open Google", "Google Chrome")
    terminal = _terminal(runner)
    runner.close()
    logger.close()

    assert accepted.status == "accepted"
    assert terminal.status == "completed"
    assert terminal.summary == "Chrome is ready."
    assert factory.commands[0][:3] == ["codex-fixture", "exec", "--json"]
    assert "$computer-use" in factory.commands[0][-1]
    assert "Google Chrome" in factory.commands[0][-1]
    assert "uncached input tokens=40" in stream.getvalue()


def test_sky_runner_rejects_apps_outside_scope() -> None:
    logger = EventLogger(stream=io.StringIO())
    runner = CodexSkyTaskRunner(
        logger,
        allowed_applications=frozenset({"Google Chrome"}),
        command=("codex-fixture",),
    )
    runner.prepare()
    try:
        result = runner.start("Read a note", "Notes")
    finally:
        runner.close()
        logger.close()

    assert result.status == "denied"


def test_sky_resume_command_preserves_session_for_steering() -> None:
    logger = EventLogger(stream=io.StringIO())
    runner = CodexSkyTaskRunner(
        logger,
        allowed_applications=frozenset({"Google Chrome"}),
        command=("codex-fixture",),
    )
    command = runner._exec_command("session-123", "Search for cats")
    runner.close()
    logger.close()

    assert command[:4] == ["codex-fixture", "exec", "resume", "--json"]
    assert "session-123" in command
    assert command[-1] == "Search for cats"
