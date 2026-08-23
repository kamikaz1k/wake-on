from __future__ import annotations

import json
import os
import select
import subprocess
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from typing import Any, BinaryIO, Literal

MCPFraming = Literal["newline", "content_length"]


class MCPError(RuntimeError):
    """Base error raised by the supervised MCP client."""


class MCPProtocolError(MCPError):
    pass


class MCPRequestTimeout(MCPError):
    def __init__(
        self,
        message: str = "MCP request timed out",
        *,
        method: str | None = None,
        tool_name: str | None = None,
        timeout_seconds: float | None = None,
    ) -> None:
        super().__init__(message)
        self.method = method
        self.tool_name = tool_name
        self.timeout_seconds = timeout_seconds


class MCPProcessStopped(MCPError):
    pass


@dataclass(frozen=True, slots=True)
class MCPToolDefinition:
    name: str
    description: str
    input_schema: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class MCPToolResult:
    content: tuple[Mapping[str, Any], ...]
    is_error: bool
    raw: Mapping[str, Any]

    @property
    def text(self) -> str:
        return "\n".join(
            str(item.get("text", ""))
            for item in self.content
            if item.get("type") == "text"
        )


class StdioMCPClient:
    """Small synchronous MCP client supervising one framed stdio server."""

    def __init__(
        self,
        command: Sequence[str],
        *,
        request_timeout_seconds: float = 15.0,
        stop_timeout_seconds: float = 1.0,
        max_frame_bytes: int = 16 * 1024 * 1024,
        framing: MCPFraming = "newline",
        cwd: str | None = None,
        environment: Mapping[str, str] | None = None,
        stderr_callback: Callable[[str], None] | None = None,
    ) -> None:
        if not command:
            raise ValueError("MCP server command cannot be empty")
        if request_timeout_seconds <= 0 or stop_timeout_seconds <= 0:
            raise ValueError("MCP timeouts must be positive")
        if max_frame_bytes <= 0:
            raise ValueError("MCP frame limit must be positive")
        if framing not in {"newline", "content_length"}:
            raise ValueError(f"unsupported MCP framing: {framing}")
        self._command = tuple(command)
        self._request_timeout = request_timeout_seconds
        self._stop_timeout = stop_timeout_seconds
        self._max_frame_bytes = max_frame_bytes
        self._framing = framing
        self._cwd = cwd
        self._environment = dict(environment) if environment is not None else None
        self._stderr_callback = stderr_callback
        self._state_lock = threading.RLock()
        self._request_lock = threading.Lock()
        self._process: subprocess.Popen[bytes] | None = None
        self._stderr_thread: threading.Thread | None = None
        self._next_request_id = 1
        self._initialized = False
        self._initialize_result: Mapping[str, Any] | None = None

    @property
    def running(self) -> bool:
        with self._state_lock:
            return self._process is not None and self._process.poll() is None

    def start(self) -> None:
        with self._state_lock:
            if self._process is not None and self._process.poll() is None:
                return
            environment = os.environ.copy()
            if self._environment is not None:
                environment.update(self._environment)
            try:
                process = subprocess.Popen(
                    self._command,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=self._cwd,
                    env=environment,
                    bufsize=0,
                )
            except OSError as error:
                raise MCPProcessStopped(
                    f"could not start MCP server {self._command[0]!r}: {error}"
                ) from error
            self._process = process
            self._initialized = False
            self._initialize_result = None
            self._next_request_id = 1
            self._stderr_thread = threading.Thread(
                target=self._drain_stderr,
                args=(process,),
                name="mcp-stderr",
                daemon=True,
            )
            self._stderr_thread.start()

    def initialize(self) -> Mapping[str, Any]:
        self.start()
        with self._state_lock:
            if self._initialized and self._initialize_result is not None:
                return self._initialize_result
        result = self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "wake-on", "version": "0.1.0"},
            },
        )
        self.notify("notifications/initialized", {})
        with self._state_lock:
            self._initialized = True
            self._initialize_result = result
        return result

    def list_tools(self) -> tuple[MCPToolDefinition, ...]:
        self.initialize()
        result = self.request("tools/list", {})
        tools = result.get("tools")
        if not isinstance(tools, list):
            raise MCPProtocolError("tools/list result did not contain a tool list")
        definitions: list[MCPToolDefinition] = []
        for item in tools:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                raise MCPProtocolError("tools/list returned an invalid tool definition")
            schema = item.get("inputSchema", {})
            if not isinstance(schema, dict):
                raise MCPProtocolError("MCP tool inputSchema must be an object")
            definitions.append(
                MCPToolDefinition(
                    name=item["name"],
                    description=str(item.get("description", "")),
                    input_schema=schema,
                )
            )
        return tuple(definitions)

    def call_tool(self, name: str, arguments: Mapping[str, Any]) -> MCPToolResult:
        self.initialize()
        result = self.request("tools/call", {"name": name, "arguments": dict(arguments)})
        content = result.get("content", [])
        if not isinstance(content, list) or not all(isinstance(item, dict) for item in content):
            raise MCPProtocolError("tools/call returned invalid content")
        return MCPToolResult(tuple(content), bool(result.get("isError", False)), result)

    def request(
        self,
        method: str,
        params: Mapping[str, Any],
        *,
        timeout_seconds: float | None = None,
    ) -> Mapping[str, Any]:
        timeout = self._request_timeout if timeout_seconds is None else timeout_seconds
        if timeout <= 0:
            raise ValueError("MCP request timeout must be positive")
        with self._request_lock:
            process = self._require_process()
            with self._state_lock:
                request_id = self._next_request_id
                self._next_request_id += 1
            message = {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": dict(params),
            }
            deadline = time.monotonic() + timeout
            try:
                self._write_frame(process, message)
                while True:
                    response = self._read_frame(process, deadline)
                    if response.get("id") != request_id:
                        if "id" not in response:
                            continue
                        raise MCPProtocolError(
                            "unexpected MCP response ID "
                            f"{response.get('id')!r}; expected {request_id}"
                        )
                    error = response.get("error")
                    if error is not None:
                        detail = error.get("message", error) if isinstance(error, dict) else error
                        raise MCPError(f"MCP {method} failed: {detail}")
                    result = response.get("result")
                    if not isinstance(result, dict):
                        raise MCPProtocolError(
                            f"MCP {method} response did not contain an object result"
                        )
                    return result
            except MCPRequestTimeout as error:
                self.stop()
                tool_name = (
                    params.get("name")
                    if method == "tools/call" and isinstance(params.get("name"), str)
                    else None
                )
                operation = f"tool {tool_name!r}" if tool_name is not None else method
                raise MCPRequestTimeout(
                    f"MCP {operation} timed out after {timeout:g}s",
                    method=method,
                    tool_name=tool_name,
                    timeout_seconds=timeout,
                ) from error
            except (MCPError, OSError, BrokenPipeError) as error:
                self.stop()
                if isinstance(error, MCPError):
                    raise
                raise MCPProcessStopped(f"MCP server stopped during {method}: {error}") from error

    def notify(self, method: str, params: Mapping[str, Any]) -> None:
        with self._request_lock:
            process = self._require_process()
            try:
                self._write_frame(
                    process,
                    {"jsonrpc": "2.0", "method": method, "params": dict(params)},
                )
            except (OSError, BrokenPipeError) as error:
                self.stop()
                raise MCPProcessStopped(f"MCP server stopped during {method}: {error}") from error

    def stop(self) -> None:
        with self._state_lock:
            process = self._process
            self._process = None
            self._initialized = False
            self._initialize_result = None
        if process is None:
            return
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                with suppress(OSError):
                    stream.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(self._stop_timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(self._stop_timeout)
        if process.stderr is not None:
            with suppress(OSError):
                process.stderr.close()

    close = stop

    def _require_process(self) -> subprocess.Popen[bytes]:
        with self._state_lock:
            process = self._process
        if process is None or process.poll() is not None:
            raise MCPProcessStopped("MCP server is not running")
        if process.stdin is None or process.stdout is None:
            raise MCPProcessStopped("MCP server stdio pipes are unavailable")
        return process

    def _write_frame(self, process: subprocess.Popen[bytes], message: Mapping[str, Any]) -> None:
        body = json.dumps(message, separators=(",", ":")).encode("utf-8")
        if len(body) > self._max_frame_bytes:
            raise MCPProtocolError("outbound MCP frame exceeds configured limit")
        assert process.stdin is not None
        if self._framing == "newline":
            frame = body + b"\n"
        else:
            frame = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        process.stdin.write(frame)
        process.stdin.flush()

    def _read_frame(
        self,
        process: subprocess.Popen[bytes],
        deadline: float,
    ) -> Mapping[str, Any]:
        assert process.stdout is not None
        if self._framing == "newline":
            body = self._read_line(process.stdout, deadline)
            return self._decode_message(body)
        headers = bytearray()
        while not (headers.endswith(b"\r\n\r\n") or headers.endswith(b"\n\n")):
            headers.extend(self._read_bytes(process.stdout, 1, deadline))
            if len(headers) > 8192:
                raise MCPProtocolError("MCP header exceeds 8192 bytes")
        content_length: int | None = None
        for line in headers.decode("ascii", errors="strict").replace("\r", "").split("\n"):
            key, separator, value = line.partition(":")
            if separator and key.strip().lower() == "content-length":
                try:
                    content_length = int(value.strip())
                except ValueError as error:
                    raise MCPProtocolError("invalid MCP Content-Length") from error
        if content_length is None or content_length < 0:
            raise MCPProtocolError("MCP frame is missing Content-Length")
        if content_length > self._max_frame_bytes:
            raise MCPProtocolError("inbound MCP frame exceeds configured limit")
        body = self._read_bytes(process.stdout, content_length, deadline)
        return self._decode_message(body)

    def _read_line(self, stream: BinaryIO, deadline: float) -> bytes:
        line = bytearray()
        while not line.endswith(b"\n"):
            line.extend(self._read_bytes(stream, 1, deadline))
            if len(line) > self._max_frame_bytes:
                raise MCPProtocolError("inbound MCP frame exceeds configured limit")
        return bytes(line).rstrip(b"\r\n")

    @staticmethod
    def _decode_message(body: bytes) -> Mapping[str, Any]:
        try:
            message = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MCPProtocolError("MCP frame contains invalid JSON") from error
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise MCPProtocolError("MCP frame is not a JSON-RPC 2.0 object")
        return message

    @staticmethod
    def _read_bytes(stream: BinaryIO, size: int, deadline: float) -> bytes:
        chunks = bytearray()
        descriptor = stream.fileno()
        while len(chunks) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise MCPRequestTimeout("MCP request timed out")
            ready, _, _ = select.select([descriptor], [], [], remaining)
            if not ready:
                raise MCPRequestTimeout("MCP request timed out")
            chunk = os.read(descriptor, size - len(chunks))
            if not chunk:
                raise MCPProcessStopped("MCP server closed stdout")
            chunks.extend(chunk)
        return bytes(chunks)

    def _drain_stderr(self, process: subprocess.Popen[bytes]) -> None:
        stream = process.stderr
        if stream is None:
            return
        try:
            for raw_line in iter(stream.readline, b""):
                if self._stderr_callback is not None:
                    self._stderr_callback(raw_line.decode("utf-8", errors="replace").rstrip())
        except (OSError, ValueError):
            return
