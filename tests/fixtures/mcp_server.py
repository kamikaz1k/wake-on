from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, BinaryIO

TOOLS = (
    "permissions",
    "see",
    "click",
    "type",
    "set_value",
    "perform_action",
    "hotkey",
    "scroll",
    "app",
    "window",
    "browser",
    "block",
)


def read_exact(stream: BinaryIO, size: int) -> bytes | None:
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def read_message(stream: BinaryIO) -> tuple[dict[str, Any], str] | None:
    first_line = stream.readline()
    if not first_line:
        return None
    if first_line.startswith(b"{"):
        return json.loads(first_line), "newline"
    headers = bytearray(first_line)
    while not (headers.endswith(b"\r\n\r\n") or headers.endswith(b"\n\n")):
        line = stream.readline()
        if not line:
            return None
        headers.extend(line)
    length = None
    for line in headers.decode("ascii").replace("\r", "").split("\n"):
        key, separator, value = line.partition(":")
        if separator and key.casefold() == "content-length":
            length = int(value.strip())
    if length is None:
        return None
    body = read_exact(stream, length)
    return (json.loads(body), "content_length") if body is not None else None


def write_message(stream: BinaryIO, message: dict[str, Any], framing: str) -> None:
    body = json.dumps(message, separators=(",", ":")).encode()
    if framing == "newline":
        stream.write(body + b"\n")
    else:
        stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    stream.flush()


def tool_result(
    text: str,
    *,
    error: bool = False,
    meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "content": [{"type": "text", "text": text}],
        "isError": error,
    }
    if meta is not None:
        result["_meta"] = meta
    return result


def append_call(path: Path | None, name: str, arguments: dict[str, Any]) -> None:
    if path is None:
        return
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"name": name, "arguments": arguments}) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=(
            "standard",
            "missing",
            "malformed",
            "no-access",
            "app-not-running",
            "see-timeout",
        ),
        default="standard",
    )
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer
    browser_connected = False

    while received := read_message(input_stream):
        message, framing = received
        method = message.get("method")
        request_id = message.get("id")
        if method == "notifications/initialized":
            continue
        if method == "initialize":
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "wake-on-test-mcp", "version": "3.9.10"},
            }
        elif method == "tools/list":
            names = TOOLS if args.mode != "missing" else ("see", "permissions")
            result = {
                "tools": [
                    {
                        "name": name,
                        "description": f"Fixture {name}",
                        "inputSchema": {"type": "object", "properties": {}},
                    }
                    for name in names
                ]
            }
        elif method == "tools/call":
            params = message.get("params", {})
            name = params.get("name", "")
            arguments = params.get("arguments", {})
            append_call(args.log, name, arguments)
            if name == "block":
                time.sleep(30)
                result = tool_result("unblocked")
            elif name == "permissions":
                if args.mode == "no-access":
                    result = tool_result(
                        "Screen Recording: Granted\nAccessibility: Not Granted (Optional)",
                        meta={"screen_recording": True, "accessibility": False},
                    )
                else:
                    result = tool_result(
                        "Screen Recording: Granted\nAccessibility: Granted",
                        meta={"screen_recording": True, "accessibility": True},
                    )
            elif name == "see":
                if args.mode == "see-timeout":
                    time.sleep(30)
                    result = tool_result("late observation")
                elif args.mode == "app-not-running":
                    result = tool_result("Application 'TextEdit' not found", error=True)
                else:
                    result = tool_result(
                        "\n".join(
                            (
                                "UI State Captured",
                                "Snapshot ID: snapshot-42",
                                f"Application: {arguments.get('app_target', 'unknown')}",
                                "Screenshot: /tmp/peekaboo-fixture.png",
                                "UI Elements:",
                                "Button fixture-button: Save",
                            )
                        ),
                        meta={"snapshot_id": "snapshot-42"},
                    )
            elif name == "browser":
                action = arguments.get("action")
                if action == "status":
                    result = tool_result(
                        "Chrome DevTools MCP Status\n\n"
                        f"Connected: {'yes' if browser_connected else 'no'}\n"
                        "Detected Chrome:\n"
                        "- Google Chrome 151.0.0.0 [stable] pid=4242"
                    )
                elif action == "connect":
                    browser_connected = True
                    result = tool_result("Connected to Google Chrome")
                elif action == "snapshot":
                    result = tool_result(
                        "Page: Fixture\nURL: https://example.test/\n"
                        "uid=page-body role=document"
                    )
                else:
                    result = tool_result(f"browser action {action} completed")
            elif name == "app" and arguments.get("action") == "list":
                result = tool_result("[info] TextEdit (PID: 4242)")
            elif arguments.get("snapshot") == "stale":
                result = tool_result("Snapshot was invalidated by an earlier command", error=True)
            else:
                result = tool_result(f"called {name}")
        else:
            write_message(
                output_stream,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown method {method}"},
                },
                framing,
            )
            continue

        if args.mode == "malformed" and method == "tools/list":
            output_stream.write(
                b"no!\n" if framing == "newline" else b"Content-Length: 3\r\n\r\nno!"
            )
            output_stream.flush()
            continue
        write_message(
            output_stream,
            {"jsonrpc": "2.0", "id": request_id, "result": result},
            framing,
        )


if __name__ == "__main__":
    main()
