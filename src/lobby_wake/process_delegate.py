from __future__ import annotations

import base64
import json
import os
import subprocess
import threading
import time
import uuid
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

import numpy as np

from .agent import (
    AudioInputOwnership,
    DelegateCapabilities,
    DelegateHealth,
    DelegatePrepareContext,
    DelegateStartContext,
    DelegateStatus,
)
from .conversation import ConversationHandle, EndConversationRequest
from .events import EventLogger
from .ring_buffer import FloatAudio

PROTOCOL_VERSION = 1
MAX_PROTOCOL_LINE_BYTES = 2 * 1024 * 1024


def encode_float_audio(samples: FloatAudio) -> dict[str, Any]:
    audio = np.asarray(samples, dtype="<f4")
    return {
        "encoding": "float32le",
        "samples": audio.size,
        "data": base64.b64encode(audio.tobytes()).decode("ascii"),
    }


class ProcessConversationDelegate:
    """Supervises a long-running delegate over a versioned JSONL protocol.

    The command is passed directly to ``subprocess.Popen`` without a shell.
    Stdout is reserved for protocol messages; stderr is forwarded to the event
    logger. A crashed process is restarted while the harness remains prepared.
    """

    def __init__(
        self,
        logger: EventLogger,
        command: Sequence[str],
        *,
        audio_input: AudioInputOwnership = AudioInputOwnership.HARNESS,
        cwd: Path | None = None,
        environment: Mapping[str, str] | None = None,
        restart_delay_seconds: float = 0.5,
        graceful_end_timeout_seconds: float = 5.0,
        shutdown_timeout_seconds: float = 1.0,
    ) -> None:
        if not command:
            raise ValueError("delegate command cannot be empty")
        if restart_delay_seconds < 0:
            raise ValueError("restart delay cannot be negative")
        if graceful_end_timeout_seconds <= 0 or shutdown_timeout_seconds <= 0:
            raise ValueError("delegate timeouts must be positive")
        self._logger = logger
        self._command = tuple(str(part) for part in command)
        self._capabilities = DelegateCapabilities(audio_input=audio_input)
        self._cwd = cwd
        self._environment = dict(environment) if environment is not None else None
        self._restart_delay_ns = round(restart_delay_seconds * 1_000_000_000)
        self._graceful_end_timeout_ns = round(
            graceful_end_timeout_seconds * 1_000_000_000
        )
        self._shutdown_timeout_seconds = shutdown_timeout_seconds
        self._state_lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        self._process_generation = 0
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None
        self._prepare_context: DelegatePrepareContext | None = None
        self._status = DelegateStatus(DelegateHealth.CREATED, accepting_activation=False)
        self._prepared = False
        self._closing = False
        self._active = False
        self._activation_id: str | None = None
        self._conversation: ConversationHandle | None = None
        self._activation_sent_at_ns: int | None = None
        self._restart_at_ns: int | None = None
        self._end_deadline_ns: int | None = None

    @property
    def capabilities(self) -> DelegateCapabilities:
        return self._capabilities

    @property
    def status(self) -> DelegateStatus:
        with self._state_lock:
            return self._status

    @property
    def active(self) -> bool:
        with self._state_lock:
            return self._active

    def prepare(self, context: DelegatePrepareContext) -> None:
        with self._state_lock:
            if self._closing:
                return
            self._prepared = True
            self._prepare_context = context
            process_running = self._process is not None and self._process.poll() is None
        if not process_running:
            self._spawn()

    def start(self, context: DelegateStartContext) -> None:
        with self._state_lock:
            if self._active:
                return
            process = self._process
            if process is None or process.poll() is not None:
                raise RuntimeError("delegate process is not available")
            if not self._status.accepting_activation:
                raise RuntimeError("delegate process is not accepting activations")
            activation_id = uuid.uuid4().hex
            self._active = True
            self._activation_id = activation_id
            self._conversation = context.conversation
            self._activation_sent_at_ns = time.monotonic_ns()
            self._end_deadline_ns = None

        message: dict[str, Any] = {
            "v": PROTOCOL_VERSION,
            "type": "start",
            "activation_id": activation_id,
            "wake": {
                "phrase": context.wake.phrase,
                "detected_at_ns": context.wake.detected_at_ns,
                "trigger_id": context.wake.trigger_id,
            },
            "sample_rate": context.sample_rate,
            "route_id": context.route_id,
        }
        if context.initial_audio is not None:
            message["initial_audio"] = encode_float_audio(context.initial_audio)
        write_started_ns = time.monotonic_ns()
        if not self._send(message):
            with self._state_lock:
                self._active = False
                self._activation_id = None
                self._conversation = None
            raise RuntimeError("failed to activate delegate process")
        self._logger.emit(
            "delegate.activation_sent",
            adapter="process",
            route_id=context.route_id,
            activation_id=activation_id,
            wake_to_delegate_start_ms=(
                time.monotonic_ns() - context.wake.detected_at_ns
            )
            / 1_000_000,
            protocol_write_ms=(time.monotonic_ns() - write_started_ns) / 1_000_000,
            initial_audio_ms=(
                context.initial_audio.size / context.sample_rate * 1000
                if context.initial_audio is not None
                else 0
            ),
        )

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None:
        if self._capabilities.audio_input is not AudioInputOwnership.HARNESS:
            return
        with self._state_lock:
            if not self._active or self._activation_id is None:
                return
            activation_id = self._activation_id
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "audio",
                "activation_id": activation_id,
                "sample_rate": sample_rate,
                "audio": encode_float_audio(samples),
            }
        )

    def poll(self) -> None:
        now_ns = time.monotonic_ns()
        with self._state_lock:
            process = self._process
            process_exited = process is not None and process.poll() is not None
            restart_due = (
                self._restart_at_ns is not None
                and now_ns >= self._restart_at_ns
                and not self._closing
            )
            end_timed_out = (
                self._active
                and self._end_deadline_ns is not None
                and now_ns >= self._end_deadline_ns
            )
        if process_exited and process is not None:
            self._record_process_exit(process, self._process_generation)
        if end_timed_out:
            self._logger.emit("delegate.graceful_end_timeout", adapter="process")
            self._terminate_and_schedule_restart(reason="graceful_end_timeout")
            return
        if restart_due:
            self._spawn()

    def request_end(self, request: EndConversationRequest) -> None:
        with self._state_lock:
            if not self._active or self._activation_id is None:
                return
            activation_id = self._activation_id
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "request_end",
                "activation_id": activation_id,
                "source": request.source,
                "reason": request.reason,
                "mode": request.mode,
                "farewell": request.farewell,
            }
        )
        if request.mode == "immediate":
            self._terminate_and_schedule_restart(reason=request.reason)
            return
        with self._state_lock:
            self._end_deadline_ns = time.monotonic_ns() + self._graceful_end_timeout_ns

    def stop(self) -> None:
        with self._state_lock:
            if not self._active or self._activation_id is None:
                return
            activation_id = self._activation_id
            self._clear_activation_locked()
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "stop",
                "activation_id": activation_id,
            }
        )

    def close(self) -> None:
        with self._state_lock:
            if self._closing:
                return
            self._closing = True
            self._prepared = False
            self._restart_at_ns = None
            process = self._process
        if process is not None and process.poll() is None:
            self._send({"v": PROTOCOL_VERSION, "type": "close"})
            try:
                process.wait(timeout=self._shutdown_timeout_seconds)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=self._shutdown_timeout_seconds)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=self._shutdown_timeout_seconds)
        with self._state_lock:
            self._process = None
            self._clear_activation_locked()
            self._status = DelegateStatus(DelegateHealth.CLOSED, accepting_activation=False)

    def _spawn(self) -> None:
        with self._state_lock:
            if self._closing or not self._prepared:
                return
            current = self._process
            if current is not None and current.poll() is None:
                return
            context = self._prepare_context
            self._restart_at_ns = None

        environment = None
        if self._environment is not None:
            environment = {**os.environ, **self._environment}
        try:
            process = subprocess.Popen(
                self._command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd=self._cwd,
                env=environment,
            )
        except OSError as error:
            self._mark_failed(f"launch failed: {error}")
            self._schedule_restart()
            return

        with self._state_lock:
            if self._closing:
                process.terminate()
                return
            self._process = process
            self._process_generation += 1
            generation = self._process_generation
            self._status = DelegateStatus(
                DelegateHealth.READY,
                accepting_activation=True,
                warm=False,
                detail="waiting for delegate readiness",
            )
        self._logger.emit(
            "delegate.process_started",
            adapter="process",
            pid=process.pid,
            process_generation=generation,
        )
        self._stdout_thread = threading.Thread(
            target=self._read_stdout,
            args=(process, generation),
            name=f"wake-on-delegate-stdout-{generation}",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._read_stderr,
            args=(process, generation),
            name=f"wake-on-delegate-stderr-{generation}",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()
        if context is not None:
            self._send(
                {
                    "v": PROTOCOL_VERSION,
                    "type": "prepare",
                    "sample_rate": context.sample_rate,
                    "audio_input": self._capabilities.audio_input,
                }
            )

    def _send(self, message: Mapping[str, Any]) -> bool:
        with self._write_lock:
            with self._state_lock:
                process = self._process
                stream = process.stdin if process is not None else None
            if process is None or stream is None or process.poll() is not None:
                return False
            try:
                stream.write(json.dumps(message, separators=(",", ":")) + "\n")
                stream.flush()
                return True
            except (BrokenPipeError, OSError, ValueError) as error:
                self._logger.emit(
                    "delegate.protocol_write_error",
                    adapter="process",
                    detail=str(error),
                )
                return False

    def _read_stdout(self, process: subprocess.Popen[str], generation: int) -> None:
        stream = process.stdout
        if stream is None:
            return
        try:
            for line in stream:
                if len(line.encode("utf-8")) > MAX_PROTOCOL_LINE_BYTES:
                    self._protocol_error("message exceeds maximum size")
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError as error:
                    self._protocol_error(f"invalid JSON: {error.msg}")
                    continue
                self._handle_message(message, generation)
        finally:
            self._record_process_exit(process, generation)

    def _read_stderr(self, process: subprocess.Popen[str], generation: int) -> None:
        stream = process.stderr
        if stream is None:
            return
        for line in stream:
            with self._state_lock:
                if generation != self._process_generation:
                    return
            message = line.rstrip("\r\n")
            if message:
                self._logger.emit(
                    "delegate.process_stderr",
                    adapter="process",
                    message=message[:2000],
                )

    def _handle_message(self, message: object, generation: int) -> None:
        with self._state_lock:
            if generation != self._process_generation:
                return
        if not isinstance(message, dict):
            self._protocol_error("message must be a JSON object")
            return
        if message.get("v") != PROTOCOL_VERSION:
            self._protocol_error("unsupported protocol version")
            return
        message_type = message.get("type")
        if message_type == "status":
            self._handle_status(message)
        elif message_type == "started":
            if self._matches_activation(message):
                with self._state_lock:
                    activation_sent_at_ns = self._activation_sent_at_ns
                self._logger.emit(
                    "delegate.activation_started",
                    adapter="process",
                    activation_id=self._activation_id,
                    activation_dispatch_ms=(
                        (time.monotonic_ns() - activation_sent_at_ns) / 1_000_000
                        if activation_sent_at_ns is not None
                        else None
                    ),
                )
        elif message_type == "ended":
            if self._matches_activation(message):
                self._finish_activation(reason=message.get("reason"))
        elif message_type == "request_end":
            self._handle_child_end_request(message)
        elif message_type == "log":
            self._logger.emit(
                "delegate.process_log",
                adapter="process",
                message=str(message.get("message", ""))[:2000],
                fields=message.get("fields") if isinstance(message.get("fields"), dict) else None,
            )
        elif message_type == "event":
            self._handle_child_event(message)
        else:
            self._protocol_error(f"unknown message type: {message_type!r}")

    def _handle_child_event(self, message: dict[str, Any]) -> None:
        event = message.get("event")
        fields = message.get("fields")
        if not isinstance(event, str) or not event.startswith("agent."):
            self._protocol_error("child event must use the agent.* namespace")
            return
        if not isinstance(fields, dict):
            fields = {}
        safe_fields = {
            str(key): value
            for key, value in fields.items()
            if key not in {"event", "monotonic_ns", "wall_time", "delegate_transport"}
        }
        self._logger.emit(
            event,
            delegate_transport="process",
            **safe_fields,
        )

    def _handle_status(self, message: dict[str, Any]) -> None:
        try:
            health = DelegateHealth(message.get("health"))
        except ValueError:
            self._protocol_error("invalid delegate health")
            return
        status = DelegateStatus(
            health=health,
            accepting_activation=bool(message.get("accepting_activation", False)),
            warm=bool(message.get("warm", False)),
            detail=(str(message["detail"])[:500] if message.get("detail") is not None else None),
        )
        with self._state_lock:
            self._status = status
        self._logger.emit(
            "delegate.status",
            adapter="process",
            health=status.health,
            accepting_activation=status.accepting_activation,
            warm=status.warm,
            detail=status.detail,
        )

    def _handle_child_end_request(self, message: dict[str, Any]) -> None:
        with self._state_lock:
            if not self._matches_activation_locked(message):
                self._logger.emit(
                    "delegate.end_request_ignored",
                    adapter="process",
                    reason="stale_activation",
                )
                return
            conversation = self._conversation
        if conversation is None:
            return
        reason = str(message.get("reason", "task_complete"))[:200]
        farewell = message.get("farewell")
        if not isinstance(farewell, str):
            farewell = None
        elif len(farewell) > 240:
            farewell = farewell[:240]
        conversation.end(
            reason=reason,
            farewell=farewell,
            immediate=bool(message.get("immediate", False)),
        )

    def _matches_activation(self, message: Mapping[str, Any]) -> bool:
        with self._state_lock:
            return self._matches_activation_locked(message)

    def _matches_activation_locked(self, message: Mapping[str, Any]) -> bool:
        return (
            self._active
            and self._activation_id is not None
            and message.get("activation_id") == self._activation_id
        )

    def _finish_activation(self, *, reason: object = None) -> None:
        with self._state_lock:
            activation_id = self._activation_id
            self._clear_activation_locked()
        self._logger.emit(
            "delegate.activation_ended",
            adapter="process",
            activation_id=activation_id,
            reason=str(reason)[:200] if reason is not None else None,
        )

    def _clear_activation_locked(self) -> None:
        self._active = False
        self._activation_id = None
        self._conversation = None
        self._activation_sent_at_ns = None
        self._end_deadline_ns = None

    def _record_process_exit(
        self,
        process: subprocess.Popen[str],
        generation: int,
    ) -> None:
        return_code = process.poll()
        if return_code is None:
            return
        with self._state_lock:
            if generation != self._process_generation or process is not self._process:
                return
            self._process = None
            was_active = self._active
            self._clear_activation_locked()
            closing = self._closing
            if not closing:
                self._status = DelegateStatus(
                    DelegateHealth.FAILED,
                    accepting_activation=False,
                    detail=f"process exited with status {return_code}",
                )
        self._logger.emit(
            "delegate.process_exited",
            adapter="process",
            process_generation=generation,
            return_code=return_code,
            during_activation=was_active,
        )
        if not closing:
            self._schedule_restart()

    def _mark_failed(self, detail: str) -> None:
        with self._state_lock:
            self._status = DelegateStatus(
                DelegateHealth.FAILED,
                accepting_activation=False,
                detail=detail[:500],
            )
        self._logger.emit("delegate.process_error", adapter="process", detail=detail[:2000])

    def _schedule_restart(self) -> None:
        with self._state_lock:
            if self._closing or not self._prepared:
                return
            self._restart_at_ns = time.monotonic_ns() + self._restart_delay_ns
            restart_in_ms = self._restart_delay_ns / 1_000_000
        self._logger.emit(
            "delegate.process_restart_scheduled",
            adapter="process",
            restart_in_ms=restart_in_ms,
        )

    def _terminate_and_schedule_restart(self, *, reason: str) -> None:
        with self._state_lock:
            process = self._process
            self._clear_activation_locked()
            if process is not None:
                self._process = None
            self._status = DelegateStatus(
                DelegateHealth.DEGRADED,
                accepting_activation=False,
                detail=f"restarting after {reason}",
            )
        if process is not None and process.poll() is None:
            process.terminate()
        self._schedule_restart()

    def _protocol_error(self, detail: str) -> None:
        self._logger.emit(
            "delegate.protocol_error",
            adapter="process",
            detail=detail[:2000],
        )
