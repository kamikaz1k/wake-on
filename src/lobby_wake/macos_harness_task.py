from __future__ import annotations

import base64
import os
import re
import subprocess
import threading
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from .mcp_stdio import MCPProcessStopped, MCPToolDefinition, MCPToolResult

_PNG_PATH = re.compile(r"(?P<path>/[^\n\r\"']+?\.png)\b")


class MacOSHarnessClient:
    """Expose macOS Harness as one batch-oriented tool to the computer planner."""

    def __init__(
        self,
        command: Sequence[str],
        *,
        timeout_seconds: float = 45.0,
        max_output_chars: int = 32_000,
    ) -> None:
        if not command:
            raise ValueError("macOS Harness command cannot be empty")
        if timeout_seconds <= 0:
            raise ValueError("macOS Harness timeout must be positive")
        self._command = tuple(command)
        self._timeout_seconds = timeout_seconds
        self._max_output_chars = max_output_chars
        self._lock = threading.RLock()
        self._process: subprocess.Popen[str] | None = None
        self._closed = False

    @property
    def running(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def list_tools(self) -> tuple[MCPToolDefinition, ...]:
        if self._closed:
            raise RuntimeError("macOS Harness client is closed")
        return (
            MCPToolDefinition(
                "run_macos_harness",
                (
                    "Run one bounded Python program with macOS Harness. The program has "
                    "preloaded mac, browser, Path, and subprocess objects. Bundle deterministic "
                    "actions and their end-state verification into one call. Print concise "
                    "observations needed for the next decision."
                ),
                {
                    "type": "object",
                    "properties": {
                        "code": {
                            "type": "string",
                            "description": "Python source to execute in macOS Harness.",
                        }
                    },
                    "required": ["code"],
                    "additionalProperties": False,
                },
            ),
        )

    def call_tool(self, name: str, arguments: Mapping[str, Any]) -> MCPToolResult:
        if name != "run_macos_harness":
            raise ValueError(f"unknown macOS Harness tool: {name}")
        code = arguments.get("code")
        if not isinstance(code, str) or not code.strip():
            raise ValueError("run_macos_harness requires non-empty Python code")

        environment = os.environ.copy()
        environment["MACOS_HARNESS_TELEMETRY"] = "0"
        with self._lock:
            if self._closed:
                raise RuntimeError("macOS Harness client is closed")
            try:
                process = subprocess.Popen(
                    self._command,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=environment,
                    start_new_session=True,
                )
            except OSError as error:
                raise MCPProcessStopped(
                    f"could not start macOS Harness {self._command[0]!r}: {error}"
                ) from error
            self._process = process

        try:
            stdout, stderr = process.communicate(code, timeout=self._timeout_seconds)
        except subprocess.TimeoutExpired as error:
            process.kill()
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"macOS Harness exceeded its {self._timeout_seconds:g}-second timeout"
            ) from error
        finally:
            with self._lock:
                if self._process is process:
                    self._process = None

        combined = self._compact_output(stdout, stderr)
        is_error = process.returncode != 0
        content: list[Mapping[str, Any]] = [{"type": "text", "text": combined}]
        screenshot = self._last_screenshot(stdout)
        if screenshot is not None:
            content.append(
                {
                    "type": "image",
                    "mimeType": "image/png",
                    "data": base64.b64encode(screenshot.read_bytes()).decode("ascii"),
                }
            )
        raw = {
            "content": content,
            "isError": is_error,
            "returncode": process.returncode,
        }
        return MCPToolResult(tuple(content), is_error, raw)

    def stop(self) -> None:
        with self._lock:
            process = self._process
        if process is not None and process.poll() is None:
            process.terminate()

    def close(self) -> None:
        with self._lock:
            self._closed = True
        self.stop()

    def _compact_output(self, stdout: str, stderr: str) -> str:
        sections: list[str] = []
        if stdout.strip():
            sections.append(stdout.strip())
        if stderr.strip():
            sections.append(f"stderr:\n{stderr.strip()}")
        text = "\n\n".join(sections) or "Program completed without printed output."
        if len(text) > self._max_output_chars:
            return text[: self._max_output_chars] + "\n[Program output truncated]"
        return text

    @staticmethod
    def _last_screenshot(stdout: str) -> Path | None:
        for match in reversed(tuple(_PNG_PATH.finditer(stdout))):
            path = Path(match.group("path"))
            try:
                if path.is_file() and path.stat().st_size > 0:
                    return path
            except OSError:
                continue
        return None


def macos_harness_instructions(
    application: str,
    allowed_applications: tuple[str, ...],
) -> str:
    allowed = ", ".join(allowed_applications)
    return (
        "You operate a Mac by writing Python programs for macOS Harness. The execution tool "
        "preloads mac, browser, Path, and subprocess. Complete the user's task, then return a "
        "concise factual result. Use one execution call per genuine decision point, not per "
        "primitive: bundle deterministic reversible actions and verify the end state once. "
        "Use mac.see/key/type/click/ax/script for native UI. Use browser for webpage DOM, tabs, "
        "network, downloads, and uploads. Common browser helpers are page_info(), current_tab(), "
        "list_tabs(), new_tab(url), goto_url(url), js(expression), scroll(x, y, dy=...), "
        "click_at_xy(x, y), fill_input(selector, text), and capture_screenshot(max_dim=1280). "
        "Print observations and results needed by the next decision. When calling mac.see or "
        "browser.capture_screenshot, print the returned dictionary or path so the screenshot "
        "is attached for vision. For compact native semantics, print the result of "
        "mac.get_app_state(app, screenshot=True, max_nodes=500). Do not invent methods; recover "
        "from an error using the exact error and the documented small surface. "
        f"Operate only in target application {application!r}. Applications available for this "
        f"session: {allowed}. Do not operate outside that scope."
    )
