from __future__ import annotations

import io
import json
import sys
import time
from pathlib import Path
from typing import Any

from lobby_wake.events import EventLogger
from lobby_wake.macos_harness_task import MacOSHarnessClient, macos_harness_instructions
from lobby_wake.peekaboo_task import PeekabooTaskRunner

FIXTURE = Path(__file__).parent / "fixtures" / "macos_harness.py"


def _response_call(code: str) -> dict[str, Any]:
    return {
        "usage": {
            "input_tokens": 0,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 0,
        },
        "output": [
            {
                "type": "function_call",
                "name": "run_macos_harness",
                "call_id": "call-1",
                "arguments": json.dumps({"code": code}),
            }
        ],
    }


def _response_done() -> dict[str, Any]:
    return {
        "usage": {
            "input_tokens": 0,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 0,
        },
        "output": [
            {
                "type": "message",
                "content": [{"type": "output_text", "text": "Fixture completed."}],
            }
        ],
    }


def _wait_for_terminal(runner: PeekabooTaskRunner) -> str:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        for event in runner.poll_events():
            if event.terminal:
                return event.status
        time.sleep(0.01)
    raise AssertionError("computer task did not finish")


def test_client_executes_program_and_attaches_printed_screenshot(tmp_path: Path) -> None:
    screenshot = tmp_path / "fixture.png"
    screenshot.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
    client = MacOSHarnessClient((sys.executable, str(FIXTURE)))

    result = client.call_tool(
        "run_macos_harness",
        {"code": f"print('result: ok')\nprint({str(screenshot)!r})"},
    )

    assert not result.is_error
    assert result.content[0] == {"type": "text", "text": f"result: ok\n{screenshot}"}
    assert result.content[1]["type"] == "image"
    assert result.content[1]["mimeType"] == "image/png"
    client.close()


def test_runner_passes_one_program_tool_and_image_back_to_model(tmp_path: Path) -> None:
    screenshot = tmp_path / "fixture.png"
    screenshot.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
    responses = iter(
        (
            _response_call(f"print('observed')\nprint({str(screenshot)!r})"),
            _response_done(),
        )
    )
    payloads: list[dict[str, Any]] = []

    def request_json(payload: dict[str, Any]) -> dict[str, Any]:
        payloads.append(payload)
        return next(responses)

    logger = EventLogger(stream=io.StringIO())
    client = MacOSHarnessClient((sys.executable, str(FIXTURE)))
    runner = PeekabooTaskRunner(
        logger,
        api_key="test-key",
        allowed_applications=frozenset({"Google Chrome"}),
        request_json=request_json,
        mcp_client=client,
        backend_name="macOS Harness",
        instructions_factory=macos_harness_instructions,
    )
    runner.prepare()
    try:
        result = runner.start("Inspect the page", "Google Chrome")
        status = _wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert result.status == "accepted"
    assert status == "completed"
    assert [tool["name"] for tool in payloads[0]["tools"]] == ["run_macos_harness"]
    output = payloads[1]["input"][-1]["output"]
    assert output[0] == {"type": "input_text", "text": f"observed\n{screenshot}"}
    assert output[1]["type"] == "input_image"
    assert output[1]["detail"] == "low"


def test_cancel_terminates_an_inflight_program() -> None:
    logger = EventLogger(stream=io.StringIO())
    client = MacOSHarnessClient((sys.executable, str(FIXTURE)), timeout_seconds=5)
    runner = PeekabooTaskRunner(
        logger,
        api_key="test-key",
        allowed_applications=frozenset({"Google Chrome"}),
        request_json=lambda payload: _response_call("import time\ntime.sleep(5)"),
        mcp_client=client,
        backend_name="macOS Harness",
        instructions_factory=macos_harness_instructions,
    )
    runner.prepare()
    try:
        accepted = runner.start("Wait", "Google Chrome")
        deadline = time.monotonic() + 1
        while not client.running and time.monotonic() < deadline:
            time.sleep(0.01)
        cancelled = runner.cancel(accepted.task_id, reason="test")
        status = _wait_for_terminal(runner)
    finally:
        runner.close()
        logger.close()

    assert cancelled.status == "cancellation_requested"
    assert status == "cancelled"
