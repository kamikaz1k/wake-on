from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import pytest

from lobby_wake.mcp_stdio import (
    MCPError,
    MCPProtocolError,
    MCPRequestTimeout,
    StdioMCPClient,
)

FIXTURE = Path(__file__).parent / "fixtures" / "mcp_server.py"


def fixture_command(*extra: str) -> tuple[str, ...]:
    return (sys.executable, str(FIXTURE), *extra)


def test_client_initializes_lists_and_calls_tools() -> None:
    client = StdioMCPClient(fixture_command())
    try:
        tools = client.list_tools()
        result = client.call_tool("permissions", {})
    finally:
        client.close()

    assert "see" in {tool.name for tool in tools}
    assert result.is_error is False
    assert "Accessibility: Granted" in result.text


def test_client_supports_content_length_framing() -> None:
    client = StdioMCPClient(fixture_command(), framing="content_length")
    try:
        assert "see" in {tool.name for tool in client.list_tools()}
    finally:
        client.close()


def test_request_timeout_stops_desynchronized_server() -> None:
    client = StdioMCPClient(fixture_command(), request_timeout_seconds=0.1)
    try:
        client.initialize()
        with pytest.raises(MCPRequestTimeout) as raised:
            client.call_tool("block", {})
        assert raised.value.method == "tools/call"
        assert raised.value.tool_name == "block"
        assert raised.value.timeout_seconds == 0.1
        assert str(raised.value) == "MCP tool 'block' timed out after 0.1s"
        assert not client.running
    finally:
        client.close()


def test_stop_interrupts_inflight_call_and_client_can_restart() -> None:
    client = StdioMCPClient(fixture_command(), request_timeout_seconds=10)
    errors: list[BaseException] = []
    started = threading.Event()

    def call_blocking_tool() -> None:
        started.set()
        try:
            client.call_tool("block", {})
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=call_blocking_tool)
    thread.start()
    assert started.wait(1)
    time.sleep(0.05)
    client.stop()
    thread.join(1)

    try:
        assert not thread.is_alive()
        assert errors and isinstance(errors[0], MCPError)
        assert "see" in {tool.name for tool in client.list_tools()}
    finally:
        client.close()


def test_malformed_frame_is_rejected_and_server_stopped() -> None:
    client = StdioMCPClient(fixture_command("--mode", "malformed"))
    try:
        with pytest.raises(MCPProtocolError):
            client.list_tools()
        assert not client.running
    finally:
        client.close()
