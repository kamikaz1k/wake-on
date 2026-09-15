from __future__ import annotations

import json
import math
import queue
import threading
import urllib.error
import urllib.request
import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

from .events import EventLogger
from .mcp_stdio import MCPToolDefinition, MCPToolResult, StdioMCPClient

RESPONSES_URL = "https://api.openai.com/v1/responses"
DEFAULT_MAX_TASK_COST_USD = 0.25

# Standard API rates per million text tokens, verified 2026-08-23:
# https://developers.openai.com/api/docs/models/gpt-5.4-mini
MODEL_TOKEN_RATES_USD: dict[str, tuple[float, float, float]] = {
    "gpt-5.4-mini": (0.75, 0.075, 4.50),
}


class PeekabooMCPClient(Protocol):
    def list_tools(self) -> tuple[MCPToolDefinition, ...]: ...

    def call_tool(self, name: str, arguments: Mapping[str, Any]) -> MCPToolResult: ...

    def stop(self) -> None: ...

    def close(self) -> None: ...


@dataclass(frozen=True, slots=True)
class ComputerToolResult:
    status: str
    summary: str
    task_id: str | None = None


@dataclass(frozen=True, slots=True)
class ComputerToolEvent:
    task_id: str
    generation: int
    status: str
    summary: str
    terminal: bool


class ComputerTaskControl(Protocol):
    @property
    def allowed_applications(self) -> tuple[str, ...]: ...

    @property
    def available_tools(self) -> tuple[str, ...]: ...

    def prepare(self) -> None: ...

    def start(self, task: str, application: str) -> ComputerToolResult: ...

    def steer(self, task_id: str | None, instruction: str) -> ComputerToolResult: ...

    def poll_events(self) -> tuple[ComputerToolEvent, ...]: ...

    def cancel(self, task_id: str | None = None, *, reason: str) -> ComputerToolResult: ...

    def close(self) -> None: ...


@dataclass(slots=True)
class _ActiveTask:
    task_id: str
    generation: int
    cancel_event: threading.Event
    steering: queue.SimpleQueue[tuple[int, str]]
    revision: int = 0
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0


class ComputerTaskRunner:
    """Runs one asynchronous computer task against Peekaboo's live MCP tools."""

    def __init__(
        self,
        logger: EventLogger,
        *,
        api_key: str,
        model: str = "gpt-5.4-mini",
        command: Sequence[str] = ("peekaboo", "mcp", "serve"),
        allowed_applications: frozenset[str],
        max_steps: int = 20,
        max_task_cost_usd: float | None = DEFAULT_MAX_TASK_COST_USD,
        response_timeout_seconds: float = 30.0,
        request_json: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
        mcp_client: PeekabooMCPClient | None = None,
        backend_name: str = "Peekaboo MCP",
        instructions_factory: Callable[[str, tuple[str, ...]], str] | None = None,
    ) -> None:
        if not api_key:
            raise ValueError("OPENAI_API_KEY is not set")
        if not allowed_applications:
            raise ValueError("at least one allowed application is required")
        if max_steps <= 0:
            raise ValueError("computer task max steps must be positive")
        if response_timeout_seconds <= 0:
            raise ValueError("computer response timeout must be positive")
        if max_task_cost_usd is not None and max_task_cost_usd <= 0:
            raise ValueError("computer task cost limit must be positive or None")
        if max_task_cost_usd is not None and model not in MODEL_TOKEN_RATES_USD:
            raise ValueError(
                f"no token pricing is configured for {model!r}; configure its rates or "
                "disable the dollar ceiling explicitly"
            )
        self._logger = logger
        self._api_key = api_key
        self._model = model
        self._allowed_applications = allowed_applications
        self._max_steps = max_steps
        self._max_task_cost_usd = max_task_cost_usd
        self._response_timeout_seconds = response_timeout_seconds
        self._request_json = request_json or self._post_response
        self._backend_name = backend_name
        self._instructions_factory = instructions_factory
        self._mcp = mcp_client or StdioMCPClient(
            command,
            stderr_callback=lambda line: self._logger.emit(
                "computer.mcp_stderr", message=line
            ),
        )
        self._lock = threading.RLock()
        self._events: queue.SimpleQueue[ComputerToolEvent] = queue.SimpleQueue()
        self._active: _ActiveTask | None = None
        self._generation = 0
        self._tools: tuple[MCPToolDefinition, ...] = ()
        self._prepared = False
        self._closed = False
        self._total_input_tokens = 0
        self._total_cached_input_tokens = 0
        self._total_output_tokens = 0
        self._total_cost_usd = 0.0

    @property
    def active_task_id(self) -> str | None:
        with self._lock:
            return self._active.task_id if self._active is not None else None

    @property
    def allowed_applications(self) -> tuple[str, ...]:
        return tuple(sorted(self._allowed_applications))

    @property
    def available_tools(self) -> tuple[str, ...]:
        with self._lock:
            return tuple(tool.name for tool in self._tools)

    def prepare(self) -> None:
        with self._lock:
            if self._closed or self._prepared:
                return
        tools = tuple(tool for tool in self._mcp.list_tools() if tool.name != "agent")
        if not tools:
            raise RuntimeError(f"{self._backend_name} did not expose any usable tools")
        with self._lock:
            if self._closed:
                self._mcp.close()
                return
            self._tools = tools
            self._prepared = True
        self._logger.emit(
            "computer.runner_ready",
            tools=[tool.name for tool in tools],
        )

    def start(self, task: str, application: str) -> ComputerToolResult:
        if application not in self._allowed_applications:
            return ComputerToolResult(
                "denied",
                f"{application} is outside the allowed app scope.",
            )
        with self._lock:
            if self._closed:
                raise RuntimeError("computer task runner is closed")
            if not self._prepared:
                raise RuntimeError("computer task runner is not prepared")
            if self._active is not None:
                return ComputerToolResult(
                    "busy",
                    "Another computer task is already running.",
                    self._active.task_id,
                )
            self._generation += 1
            active = _ActiveTask(
                uuid.uuid4().hex,
                self._generation,
                threading.Event(),
                queue.SimpleQueue(),
            )
            self._active = active
            thread = threading.Thread(
                target=self._run,
                args=(active, task, application),
                name=f"computer-task-{active.task_id}",
                daemon=True,
            )
        thread.start()
        return ComputerToolResult("accepted", "Computer task started.", active.task_id)

    def steer(
        self,
        task_id: str | None,
        instruction: str,
    ) -> ComputerToolResult:
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
            active.revision += 1
            revision = active.revision
            active.steering.put((revision, instruction))
        self._logger.emit(
            "computer.task_steer_requested",
            task_id=active.task_id,
            generation=active.generation,
            revision=revision,
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
        self._mcp.stop()
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
        self._mcp.close()
        self._logger.emit("computer.runner_closed")

    def _run(self, active: _ActiveTask, task: str, application: str) -> None:
        self._logger.emit(
            "computer.task_started",
            task_id=active.task_id,
            generation=active.generation,
            application=application,
        )
        try:
            summary = self._run_agent_loop(active, task, application)
        except Exception as error:
            if active.cancel_event.is_set():
                self._finish(active, "cancelled", "Computer task cancelled.")
            else:
                self._logger.emit(
                    "computer.task_error",
                    task_id=active.task_id,
                    generation=active.generation,
                    error_type=type(error).__name__,
                )
                self._finish(active, "failed", str(error)[:500] or "Computer task failed.")
            return
        if active.cancel_event.is_set():
            self._finish(active, "cancelled", "Computer task cancelled.")
        else:
            self._finish(active, "completed", summary or "Computer task complete.")

    def _run_agent_loop(
        self,
        active: _ActiveTask,
        task: str,
        application: str,
    ) -> str:
        with self._lock:
            tools = self._tools
        input_items: list[dict[str, Any]] = [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            f"Target application: {application}\n"
                            f"Task: {task}"
                        ),
                    }
                ],
            }
        ]
        for step in range(1, self._max_steps + 1):
            self._raise_if_cancelled(active)
            self._append_latest_steering(active, input_items)
            payload = {
                "model": self._model,
                "instructions": self._instructions(application),
                "input": list(input_items),
                "tools": [self._responses_tool(tool) for tool in tools],
                "tool_choice": "auto",
                "parallel_tool_calls": False,
            }
            self._check_projected_request_cost(active, payload, step)
            response = self._request_json(payload)
            self._raise_if_cancelled(active)
            self._record_response_usage(active, response, step)
            # A model response planned against the old goal must never dispatch a new
            # UI action after steering has been accepted. Discard it and re-plan.
            if self._append_latest_steering(active, input_items):
                continue
            output = response.get("output")
            if not isinstance(output, list):
                raise ValueError("OpenAI Responses result did not contain output items")
            input_items.extend(item for item in output if isinstance(item, dict))
            calls = [
                item
                for item in output
                if isinstance(item, dict) and item.get("type") == "function_call"
            ]
            if not calls:
                if self._append_latest_steering(active, input_items):
                    continue
                return self._extract_output_text(response)
            for call_index, call in enumerate(calls):
                self._raise_if_cancelled(active)
                name = call.get("name")
                call_id = call.get("call_id")
                if not isinstance(name, str) or not isinstance(call_id, str):
                    raise ValueError("OpenAI Responses returned an invalid MCP tool call")
                arguments = self._parse_arguments(call.get("arguments"))
                self._logger.emit(
                    "computer.mcp_tool_started",
                    task_id=active.task_id,
                    generation=active.generation,
                    step=step,
                    tool=name,
                )
                result = self._mcp.call_tool(name, arguments)
                self._raise_if_cancelled(active)
                input_items.append(
                    {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": self._model_tool_output(result),
                    }
                )
                self._events.put(
                    ComputerToolEvent(
                        active.task_id,
                        active.generation,
                        "progress",
                        f"{self._backend_name} operation completed.",
                        False,
                    )
                )
                self._logger.emit(
                    "computer.mcp_tool_completed",
                    task_id=active.task_id,
                    generation=active.generation,
                    step=step,
                    tool=name,
                    tool_error=result.is_error,
                )
                if self._append_latest_steering(active, input_items):
                    # Responses requires an output for every function call it emitted.
                    # Mark unstarted calls as skipped before asking for a revised plan.
                    for skipped in calls[call_index + 1 :]:
                        skipped_call_id = skipped.get("call_id")
                        if isinstance(skipped_call_id, str):
                            input_items.append(
                                {
                                    "type": "function_call_output",
                                    "call_id": skipped_call_id,
                                    "output": "Skipped because the user changed the goal.",
                                }
                            )
                    break
        raise RuntimeError(f"Computer task exceeded its {self._max_steps}-step limit.")

    def _check_projected_request_cost(
        self,
        active: _ActiveTask,
        payload: Mapping[str, Any],
        step: int,
    ) -> None:
        rates = MODEL_TOKEN_RATES_USD.get(self._model)
        payload_bytes = len(
            json.dumps(payload, separators=(",", ":"), default=EventLogger.json_default).encode(
                "utf-8"
            )
        )
        estimated_input_tokens = math.ceil(payload_bytes / 4)
        estimated_input_cost = (
            estimated_input_tokens * rates[0] / 1_000_000 if rates is not None else None
        )
        self._logger.emit(
            "computer.model_request_budget",
            task_id=active.task_id,
            generation=active.generation,
            step=step,
            model=self._model,
            payload_bytes=payload_bytes,
            estimated_input_tokens=estimated_input_tokens,
            estimated_input_cost_usd=estimated_input_cost,
            task_cost_usd=active.cost_usd,
            max_task_cost_usd=self._max_task_cost_usd,
        )
        if (
            self._max_task_cost_usd is not None
            and estimated_input_cost is not None
            and active.cost_usd + estimated_input_cost > self._max_task_cost_usd
        ):
            raise RuntimeError(
                "Computer task stopped before the next model request because its projected "
                f"cost would exceed ${self._max_task_cost_usd:.2f}."
            )

    def _record_response_usage(
        self,
        active: _ActiveTask,
        response: Mapping[str, Any],
        step: int,
    ) -> None:
        usage = response.get("usage")
        if not isinstance(usage, Mapping):
            self._logger.emit(
                "computer.model_usage_missing",
                task_id=active.task_id,
                generation=active.generation,
                step=step,
                model=self._model,
            )
            if self._max_task_cost_usd is not None:
                raise RuntimeError(
                    "Computer task stopped because the model response omitted token usage, "
                    "so its cost budget could not be enforced."
                )
            return
        input_tokens = self._nonnegative_int(usage.get("input_tokens"))
        output_tokens = self._nonnegative_int(usage.get("output_tokens"))
        input_details = usage.get("input_tokens_details")
        cached_tokens = (
            self._nonnegative_int(input_details.get("cached_tokens"))
            if isinstance(input_details, Mapping)
            else 0
        )
        cached_tokens = min(cached_tokens, input_tokens)
        rates = MODEL_TOKEN_RATES_USD.get(self._model)
        request_cost: float | None = None
        if rates is not None:
            input_rate, cached_rate, output_rate = rates
            request_cost = (
                (input_tokens - cached_tokens) * input_rate
                + cached_tokens * cached_rate
                + output_tokens * output_rate
            ) / 1_000_000
            active.cost_usd += request_cost
        active.input_tokens += input_tokens
        active.cached_input_tokens += cached_tokens
        active.output_tokens += output_tokens
        with self._lock:
            self._total_input_tokens += input_tokens
            self._total_cached_input_tokens += cached_tokens
            self._total_output_tokens += output_tokens
            if request_cost is not None:
                self._total_cost_usd += request_cost
            runner_cost_usd = self._total_cost_usd if rates is not None else None
        self._logger.emit(
            "computer.model_usage",
            task_id=active.task_id,
            generation=active.generation,
            step=step,
            model=self._model,
            input_tokens=input_tokens,
            cached_input_tokens=cached_tokens,
            output_tokens=output_tokens,
            total_tokens=input_tokens + output_tokens,
            request_cost_usd=request_cost,
            task_cost_usd=active.cost_usd if rates is not None else None,
            runner_cost_usd=runner_cost_usd,
            max_task_cost_usd=self._max_task_cost_usd,
        )
        if (
            self._max_task_cost_usd is not None
            and request_cost is not None
            and active.cost_usd > self._max_task_cost_usd
        ):
            raise RuntimeError(
                "Computer task stopped because its model cost exceeded "
                f"${self._max_task_cost_usd:.2f}."
            )

    @staticmethod
    def _nonnegative_int(value: Any) -> int:
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0

    def _append_latest_steering(
        self,
        active: _ActiveTask,
        input_items: list[dict[str, Any]],
    ) -> bool:
        latest: tuple[int, str] | None = None
        while True:
            try:
                latest = active.steering.get_nowait()
            except queue.Empty:
                break
        if latest is None:
            return False
        revision, instruction = latest
        input_items.append(
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            f"Goal revision {revision}: {instruction}\n"
                            "This supersedes incompatible parts of the previous goal. "
                            "Re-observe if the screen may have changed, then continue from "
                            "the current state."
                        ),
                    }
                ],
            }
        )
        self._events.put(
            ComputerToolEvent(
                active.task_id,
                active.generation,
                "steered",
                f"Computer task updated to goal revision {revision}.",
                False,
            )
        )
        self._logger.emit(
            "computer.task_steered",
            task_id=active.task_id,
            generation=active.generation,
            revision=revision,
        )
        return True

    @staticmethod
    def _model_tool_output(
        result: MCPToolResult, *, max_text_chars: int = 32_000
    ) -> str | list[dict[str, Any]]:
        text_items = [
            str(item.get("text", ""))
            for item in result.content
            if item.get("type") == "text"
        ]
        text = "\n".join(text_items)
        if len(text) > max_text_chars:
            text = text[:max_text_chars] + "\n[Tool output truncated]"
        if result.is_error:
            text = f"Error: {text or 'Tool failed without a text explanation.'}"
        images = [
            item
            for item in result.content
            if item.get("type") == "image" and isinstance(item.get("data"), str)
        ]
        if images:
            output: list[dict[str, Any]] = [
                {"type": "input_text", "text": text or "Success"}
            ]
            for item in images[-1:]:
                mime_type = str(item.get("mimeType") or "image/png")
                output.append(
                    {
                        "type": "input_image",
                        "detail": "low",
                        "image_url": f"data:{mime_type};base64,{item['data']}",
                    }
                )
            return output
        if text_items or result.is_error:
            return text
        if not result.content:
            return "Success"
        first = result.content[0]
        content_type = str(first.get("type", "content"))
        data = first.get("data")
        size = len(data) if isinstance(data, (str, bytes)) else None
        suffix = f", encoded size: {size} bytes" if size is not None else ""
        return f"[{content_type}{suffix}]"

    def _finish(self, active: _ActiveTask, status: str, summary: str) -> None:
        with self._lock:
            if self._active == active:
                self._active = None
            runner_cost_usd = (
                self._total_cost_usd if self._model in MODEL_TOKEN_RATES_USD else None
            )
        self._events.put(
            ComputerToolEvent(
                active.task_id,
                active.generation,
                status,
                summary,
                True,
            )
        )
        self._logger.emit(
            "computer.task_finished",
            task_id=active.task_id,
            generation=active.generation,
            status=status,
            model=self._model,
            input_tokens=active.input_tokens,
            cached_input_tokens=active.cached_input_tokens,
            output_tokens=active.output_tokens,
            estimated_cost_usd=(
                active.cost_usd if self._model in MODEL_TOKEN_RATES_USD else None
            ),
            runner_estimated_cost_usd=runner_cost_usd,
            max_task_cost_usd=self._max_task_cost_usd,
        )

    def _instructions(self, application: str) -> str:
        allowed_applications = tuple(sorted(self._allowed_applications))
        if self._instructions_factory is not None:
            return self._instructions_factory(application, allowed_applications)
        allowed = ", ".join(allowed_applications)
        return (
            "You operate macOS through Peekaboo MCP. Complete the requested task by calling "
            "the provided tools. Their descriptions and JSON schemas are authoritative; do "
            "not invent tool names or arguments. Verify consequential effects with an "
            "appropriate observation tool before declaring success. Return a concise factual "
            f"result. Operate only in the target application {application!r}. The applications "
            f"available for this session are: {allowed}. Do not operate outside that scope."
        )

    @staticmethod
    def _responses_tool(tool: MCPToolDefinition) -> dict[str, Any]:
        return {
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.input_schema,
            "strict": False,
        }

    @staticmethod
    def _parse_arguments(arguments: Any) -> dict[str, Any]:
        parsed = json.loads(arguments or "{}") if isinstance(arguments, str) else arguments
        if not isinstance(parsed, dict):
            raise ValueError("OpenAI Responses tool arguments must be a JSON object")
        return parsed

    @staticmethod
    def _extract_output_text(response: Mapping[str, Any]) -> str:
        direct = response.get("output_text")
        if isinstance(direct, str) and direct.strip():
            return direct.strip()
        for item in response.get("output") or []:
            if not isinstance(item, dict) or item.get("type") != "message":
                continue
            for content in item.get("content") or []:
                if (
                    isinstance(content, dict)
                    and content.get("type") == "output_text"
                    and isinstance(content.get("text"), str)
                ):
                    return content["text"].strip()
        raise ValueError("OpenAI Responses result did not contain final output text")

    @staticmethod
    def _raise_if_cancelled(active: _ActiveTask) -> None:
        if active.cancel_event.is_set():
            raise RuntimeError("computer task cancelled")

    def _post_response(self, payload: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            RESPONSES_URL,
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request, timeout=self._response_timeout_seconds
            ) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")[:1000]
            raise RuntimeError(
                f"OpenAI Responses request failed ({error.code}): {detail}"
            ) from error
        if not isinstance(result, dict):
            raise ValueError("OpenAI Responses result was not an object")
        return result


# Compatibility for the historical public name while callers migrate to the
# provider-neutral lifecycle name.
PeekabooTaskRunner = ComputerTaskRunner
