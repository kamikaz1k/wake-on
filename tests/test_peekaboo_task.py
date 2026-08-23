from __future__ import annotations

import io
import json
import threading
import time
from collections.abc import Mapping
from typing import Any

import pytest

from lobby_wake.events import EventLogger
from lobby_wake.mcp_stdio import MCPError, MCPToolDefinition, MCPToolResult
from lobby_wake.peekaboo_task import PeekabooTaskRunner


class FakeMCPClient:
    def __init__(self) -> None:
        self.schema = {
            "type": "object",
            "properties": {
                "keys": {"type": "array", "items": {"type": "string"}},
                "app": {"type": "string"},
            },
            "required": ["keys"],
            "additionalProperties": False,
        }
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.call_started = threading.Event()
        self.release_call = threading.Event()
        self.block_calls = False
        self.stopped = False
        self.closed = False

    def list_tools(self) -> tuple[MCPToolDefinition, ...]:
        return (
            MCPToolDefinition("hotkey", "Press a key combination.", self.schema),
            MCPToolDefinition("agent", "Nested agent that should not be exposed.", {}),
        )

    def call_tool(self, name: str, arguments: Mapping[str, Any]) -> MCPToolResult:
        self.calls.append((name, dict(arguments)))
        self.call_started.set()
        if self.block_calls:
            self.release_call.wait(2)
        if self.stopped:
            raise MCPError("MCP stopped")
        raw = {
            "content": [{"type": "text", "text": "shortcut delivered"}],
            "isError": False,
        }
        return MCPToolResult(tuple(raw["content"]), False, raw)

    def stop(self) -> None:
        self.stopped = True
        self.release_call.set()

    def close(self) -> None:
        self.closed = True
        self.stop()


def response_call(name: str, arguments: str) -> dict[str, Any]:
    return {
        "id": "response-1",
        "usage": {
            "input_tokens": 0,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 0,
        },
        "output": [
            {
                "type": "function_call",
                "name": name,
                "call_id": "call-1",
                "arguments": arguments,
            }
        ],
    }


def response_done(text: str = "Done.") -> dict[str, Any]:
    return {
        "id": "response-2",
        "usage": {
            "input_tokens": 0,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 0,
        },
        "output": [
            {
                "type": "message",
                "content": [{"type": "output_text", "text": text}],
            }
        ],
    }


def wait_for_terminal(runner: PeekabooTaskRunner) -> tuple[str, str]:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        for event in runner.poll_events():
            if event.terminal:
                return event.status, event.summary
        time.sleep(0.01)
    raise AssertionError("computer task did not finish")


def make_runner(
    mcp: FakeMCPClient,
    request_json: Any,
) -> tuple[PeekabooTaskRunner, EventLogger]:
    logger = EventLogger(stream=io.StringIO())
    runner = PeekabooTaskRunner(
        logger,
        api_key="test-key",
        allowed_applications=frozenset({"Google Chrome"}),
        request_json=request_json,
        mcp_client=mcp,
    )
    runner.prepare()
    return runner, logger


def test_live_mcp_schema_and_tool_arguments_pass_through_unchanged() -> None:
    mcp = FakeMCPClient()
    payloads: list[dict[str, Any]] = []
    responses = iter(
        (
            response_call(
                "hotkey", '{"keys":["RETURN"],"app":"Google Chrome"}'
            ),
            response_done("The search was submitted."),
        )
    )

    def request_json(payload: dict[str, Any]) -> dict[str, Any]:
        payloads.append(payload)
        return next(responses)

    runner, logger = make_runner(mcp, request_json)
    try:
        accepted = runner.start("Submit the search", "Google Chrome")
        status, summary = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert accepted.status == "accepted"
    assert status == "completed"
    assert summary == "The search was submitted."
    assert payloads[0]["tools"] == [
        {
            "type": "function",
            "name": "hotkey",
            "description": "Press a key combination.",
            "parameters": mcp.schema,
            "strict": False,
        }
    ]
    assert mcp.calls == [
        ("hotkey", {"keys": ["RETURN"], "app": "Google Chrome"})
    ]
    assert payloads[1]["input"][-1]["type"] == "function_call_output"


def test_start_is_immediate_and_one_task_runs_at_a_time() -> None:
    mcp = FakeMCPClient()
    request_started = threading.Event()
    release_request = threading.Event()

    def request_json(payload: dict[str, Any]) -> dict[str, Any]:
        request_started.set()
        release_request.wait(2)
        return response_done()

    runner, logger = make_runner(mcp, request_json)
    try:
        started_at = time.monotonic()
        accepted = runner.start("Wait in the background", "Google Chrome")
        elapsed = time.monotonic() - started_at
        assert request_started.wait(1)
        busy = runner.start("A second task", "Google Chrome")
        release_request.set()
        status, _ = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert elapsed < 0.1
    assert accepted.status == "accepted"
    assert busy.status == "busy"
    assert busy.task_id == accepted.task_id
    assert status == "completed"


def test_cancel_stops_inflight_mcp_call_and_dominates_late_failure() -> None:
    mcp = FakeMCPClient()
    mcp.block_calls = True
    runner, logger = make_runner(
        mcp,
        lambda payload: response_call("hotkey", '{"keys":["ESCAPE"]}'),
    )
    try:
        accepted = runner.start("Do something slow", "Google Chrome")
        assert accepted.task_id is not None
        assert mcp.call_started.wait(1)
        cancelled = runner.cancel(accepted.task_id, reason="model_requested")
        status, summary = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert cancelled.status == "cancellation_requested"
    assert mcp.stopped
    assert status == "cancelled"
    assert summary == "Computer task cancelled."


def test_steer_discards_stale_model_plan_before_it_can_act() -> None:
    mcp = FakeMCPClient()
    first_request_started = threading.Event()
    release_first_request = threading.Event()
    payloads: list[dict[str, Any]] = []

    def request_json(payload: dict[str, Any]) -> dict[str, Any]:
        payloads.append(payload)
        if len(payloads) == 1:
            first_request_started.set()
            release_first_request.wait(2)
            return response_call("hotkey", '{"keys":["RETURN"]}')
        return response_done("Stayed on the current page as requested.")

    runner, logger = make_runner(mcp, request_json)
    try:
        accepted = runner.start("Submit the form", "Google Chrome")
        assert accepted.task_id is not None
        assert first_request_started.wait(1)
        steered = runner.steer(
            accepted.task_id,
            "Do not submit. Stay on the current page instead.",
        )
        release_first_request.set()
        status, summary = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert steered.status == "steering_accepted"
    assert steered.task_id == accepted.task_id
    assert mcp.calls == []
    assert status == "completed"
    assert summary == "Stayed on the current page as requested."
    revised_input = payloads[1]["input"][-1]["content"][0]["text"]
    assert "Goal revision 1" in revised_input
    assert "Do not submit" in revised_input


def test_tool_result_is_compacted_before_returning_to_model() -> None:
    mcp = FakeMCPClient()
    payloads: list[dict[str, Any]] = []
    responses = iter((response_call("hotkey", '{"keys":["RETURN"]}'), response_done()))

    def request_json(payload: dict[str, Any]) -> dict[str, Any]:
        payloads.append(payload)
        return next(responses)

    runner, logger = make_runner(mcp, request_json)
    try:
        runner.start("Submit", "Google Chrome")
        status, _ = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert status == "completed"
    assert payloads[1]["input"][-1]["output"] == "shortcut delivered"
    assert '"content"' not in payloads[1]["input"][-1]["output"]


def test_exact_response_usage_and_cost_are_logged(tmp_path: Any) -> None:
    mcp = FakeMCPClient()
    output = tmp_path / "computer-cost.jsonl"
    logger = EventLogger(output, stream=io.StringIO())
    response = response_done("Done.")
    response["usage"] = {
        "input_tokens": 10_000,
        "input_tokens_details": {"cached_tokens": 4_000},
        "output_tokens": 1_000,
        "total_tokens": 11_000,
    }
    runner = PeekabooTaskRunner(
        logger,
        api_key="test-key",
        allowed_applications=frozenset({"Google Chrome"}),
        request_json=lambda payload: response,
        mcp_client=mcp,
    )
    runner.prepare()
    try:
        runner.start("Inspect the page", "Google Chrome")
        status, _ = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert status == "completed"
    records = [json.loads(line) for line in output.read_text().splitlines()]
    usage = next(record for record in records if record["event"] == "computer.model_usage")
    # 6K uncached × $0.75/M + 4K cached × $0.075/M + 1K output × $4.50/M.
    assert usage["request_cost_usd"] == pytest.approx(0.0093)
    assert usage["runner_cost_usd"] == pytest.approx(0.0093)
    finished = next(
        record for record in records if record["event"] == "computer.task_finished"
    )
    assert finished["estimated_cost_usd"] == pytest.approx(0.0093)
    assert finished["runner_estimated_cost_usd"] == pytest.approx(0.0093)


def test_cost_ceiling_stops_task_before_model_plan_can_act() -> None:
    mcp = FakeMCPClient()
    response = response_call("hotkey", '{"keys":["RETURN"]}')
    response["usage"] = {
        "input_tokens": 200_000,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens": 1_000,
    }
    logger = EventLogger(stream=io.StringIO())
    runner = PeekabooTaskRunner(
        logger,
        api_key="test-key",
        allowed_applications=frozenset({"Google Chrome"}),
        max_task_cost_usd=0.10,
        request_json=lambda payload: response,
        mcp_client=mcp,
    )
    runner.prepare()
    try:
        runner.start("Submit", "Google Chrome")
        status, summary = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert status == "failed"
    assert "cost exceeded $0.10" in summary
    assert mcp.calls == []


def test_cost_ceiling_fails_closed_when_usage_is_missing() -> None:
    mcp = FakeMCPClient()
    response = response_done()
    del response["usage"]
    runner, logger = make_runner(mcp, lambda payload: response)
    try:
        runner.start("Inspect", "Google Chrome")
        status, summary = wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert status == "failed"
    assert "omitted token usage" in summary


def test_unknown_model_requires_explicitly_disabling_dollar_ceiling() -> None:
    logger = EventLogger(stream=io.StringIO())
    with pytest.raises(ValueError, match="no token pricing is configured"):
        PeekabooTaskRunner(
            logger,
            api_key="test-key",
            model="custom-model",
            allowed_applications=frozenset({"Google Chrome"}),
            mcp_client=FakeMCPClient(),
        )
    logger.close()


def test_application_scope_is_checked_before_start() -> None:
    mcp = FakeMCPClient()
    runner, logger = make_runner(mcp, lambda payload: response_done())
    try:
        result = runner.start("Send a message", "Messages")
    finally:
        runner.close()
        logger.close()

    assert result.status == "denied"
    assert runner.allowed_applications == ("Google Chrome",)
    assert runner.available_tools == ("hotkey",)
