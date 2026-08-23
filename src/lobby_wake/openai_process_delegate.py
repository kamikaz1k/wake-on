from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import queue
import shlex
import sys
import threading
import time
import traceback
from collections.abc import Callable
from typing import Any, TextIO

import numpy as np
from dotenv import load_dotenv

from .agent import DelegatePrepareContext, DelegateStartContext
from .conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from .events import EventLogger, WakeEvent
from .peekaboo_task import DEFAULT_MAX_TASK_COST_USD, PeekabooTaskRunner
from .playback import AudioPlayback, PlaybackPosition
from .process_delegate import MAX_PROTOCOL_LINE_BYTES, PROTOCOL_VERSION, encode_pcm16_audio
from .realtime import DEFAULT_INSTRUCTIONS, OpenAIRealtimeAgent
from .ring_buffer import FloatAudio


class ProtocolWriter:
    """Non-blocking, thread-safe protocol output for Realtime callbacks."""

    def __init__(self, stream: TextIO = sys.stdout) -> None:
        self._stream = stream
        self._queue: queue.SimpleQueue[dict[str, Any] | None] = queue.SimpleQueue()
        self._thread = threading.Thread(
            target=self._run,
            name="wake-on-openai-protocol-writer",
            daemon=True,
        )
        self._thread.start()

    def emit(self, message_type: str, **fields: Any) -> None:
        self._queue.put({"v": PROTOCOL_VERSION, "type": message_type, **fields})

    def close(self) -> None:
        self._queue.put(None)
        self._thread.join(timeout=2)

    def _run(self) -> None:
        while (message := self._queue.get()) is not None:
            print(
                json.dumps(
                    message,
                    separators=(",", ":"),
                    default=EventLogger.json_default,
                ),
                file=self._stream,
                flush=True,
            )


class BridgeLogger:
    """Forwards existing agent metrics to the supervising parent."""

    def __init__(self, writer: ProtocolWriter) -> None:
        self._writer = writer

    def emit(self, event: str, **fields: Any) -> int:
        now_ns = time.monotonic_ns()
        if event.startswith(("agent.", "computer.")):
            self._writer.emit(
                "event",
                event=event,
                fields=fields,
                child_monotonic_ns=now_ns,
            )
        return now_ns

    def close(self) -> None:
        pass


class ProtocolAudioPlayback:
    """Child-side playback proxy for harness-owned conversation media."""

    def __init__(
        self,
        writer: ProtocolWriter,
        sample_rate: int,
        activation_id: Callable[[], str | None],
    ) -> None:
        self._writer = writer
        self.sample_rate = sample_rate
        self._activation_id = activation_id
        self._lock = threading.Lock()
        self._playing = False
        self._started_at_ns: int | None = None
        self._queued_samples = 0
        self._item_ranges: dict[tuple[str, int], tuple[int, int]] = {}
        self._latest_key: tuple[str, int] | None = None

    @property
    def playing(self) -> bool:
        with self._lock:
            return self._playing

    def start(self) -> None:
        pass

    def enqueue(
        self,
        pcm16: bytes,
        on_start: Callable[[], None] | None = None,
        *,
        item_id: str = "",
        content_index: int = 0,
    ) -> None:
        activation_id = self._activation_id()
        if not pcm16 or activation_id is None:
            return
        with self._lock:
            if not self._playing:
                self._started_at_ns = time.monotonic_ns()
                self._queued_samples = 0
            self._playing = True
            key = (item_id, content_index)
            chunk_samples = len(pcm16) // 2
            item_start, item_samples = self._item_ranges.get(
                key, (self._queued_samples, 0)
            )
            self._item_ranges[key] = (item_start, item_samples + chunk_samples)
            self._queued_samples += chunk_samples
            self._latest_key = key
        self._writer.emit(
            "playback_audio",
            activation_id=activation_id,
            item_id=item_id,
            content_index=content_index,
            audio=encode_pcm16_audio(pcm16),
        )
        if on_start is not None:
            on_start()

    def clear(self) -> None:
        self.interrupt()

    def interrupt(
        self,
        item_id: str | None = None,
        content_index: int = 0,
    ) -> PlaybackPosition | None:
        activation_id = self._activation_id()
        with self._lock:
            key = (item_id, content_index) if item_id is not None else self._latest_key
            started_at_ns = self._started_at_ns
            item_start, item_samples = self._item_ranges.get(key, (0, 0))
            self._reset_locked()
        if activation_id is not None:
            self._writer.emit(
                "playback_clear",
                activation_id=activation_id,
                item_id=key[0] if key is not None else None,
                content_index=key[1] if key is not None else 0,
            )
        if key is None:
            return None
        elapsed_samples = (
            round((time.monotonic_ns() - started_at_ns) / 1_000_000_000 * self.sample_rate)
            if started_at_ns is not None
            else 0
        )
        return PlaybackPosition(
            item_id=key[0],
            content_index=key[1],
            audio_end_ms=min(item_samples, max(0, elapsed_samples - item_start))
            * 1000
            // self.sample_rate,
        )

    def close(self) -> None:
        self.clear()

    def mark_idle(self) -> None:
        with self._lock:
            self._reset_locked()

    def _reset_locked(self) -> None:
        self._playing = False
        self._started_at_ns = None
        self._queued_samples = 0
        self._item_ranges.clear()
        self._latest_key = None


def decode_float_audio(value: object) -> FloatAudio:
    if not isinstance(value, dict) or value.get("encoding") != "float32le":
        raise ValueError("audio must use float32le encoding")
    encoded = value.get("data")
    samples = value.get("samples")
    if not isinstance(encoded, str) or not isinstance(samples, int) or samples < 0:
        raise ValueError("audio payload is missing data or sample count")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("audio payload is not valid base64") from error
    if len(raw) != samples * 4:
        raise ValueError("audio byte length does not match sample count")
    return np.frombuffer(raw, dtype="<f4").astype(np.float32, copy=False)


class OpenAIProcessWorker:
    def __init__(
        self,
        writer: ProtocolWriter,
        agent_factory: Callable[
            [BridgeLogger, ConversationController, AudioPlayback | None],
            OpenAIRealtimeAgent,
        ],
    ) -> None:
        self._writer = writer
        self._logger = BridgeLogger(writer)
        self._agent_factory = agent_factory
        self._controller = ConversationController(self._logger)  # type: ignore[arg-type]
        self._agent: OpenAIRealtimeAgent | None = None
        self._playback: ProtocolAudioPlayback | None = None
        self._activation_id: str | None = None
        self._last_status: tuple[object, ...] | None = None

    def handle(self, message: object) -> bool:
        if not isinstance(message, dict) or message.get("v") != PROTOCOL_VERSION:
            raise ValueError("invalid delegate protocol message")
        message_type = message.get("type")
        if message_type == "prepare":
            self._prepare(message)
        elif message_type == "start":
            self._start(message)
        elif message_type == "audio":
            self._audio(message)
        elif message_type == "request_end":
            self._request_end(message)
        elif message_type == "stop":
            self._stop(message)
        elif message_type == "playback_idle":
            if self._playback is not None:
                self._playback.mark_idle()
        elif message_type == "close":
            return False
        else:
            raise ValueError(f"unsupported parent message: {message_type!r}")
        return True

    def poll(self) -> None:
        agent = self._agent
        if agent is None:
            return
        agent.poll()
        request = self._controller.take_request()
        if request is not None and self._activation_id is not None:
            self._writer.emit(
                "request_end",
                activation_id=self._activation_id,
                reason=request.reason,
                farewell=request.farewell,
                immediate=request.mode is EndMode.IMMEDIATE,
            )
        if self._activation_id is not None and not agent.active:
            self._finish_activation(reason="agent_inactive")
        self._publish_status()

    def close(self) -> None:
        if self._agent is not None:
            self._agent.close()
        self._controller.finish()
        self._activation_id = None
        self._writer.emit(
            "status",
            health="closed",
            accepting_activation=False,
            warm=False,
        )

    def _prepare(self, message: dict[str, Any]) -> None:
        if message.get("audio_input") != "harness":
            raise ValueError("OpenAI WebSocket delegate requires harness-owned audio")
        sample_rate = message.get("sample_rate")
        if not isinstance(sample_rate, int) or sample_rate <= 0:
            raise ValueError("prepare requires a positive sample rate")
        if self._agent is None:
            output = message.get("audio_output")
            if isinstance(output, dict) and output.get("owner") == "harness":
                output_sample_rate = output.get("sample_rate")
                if not isinstance(output_sample_rate, int) or output_sample_rate <= 0:
                    raise ValueError("harness audio output requires a positive sample rate")
                self._playback = ProtocolAudioPlayback(
                    self._writer,
                    output_sample_rate,
                    lambda: self._activation_id,
                )
            self._agent = self._agent_factory(
                self._logger,
                self._controller,
                self._playback,
            )
            self._agent.prepare(DelegatePrepareContext(sample_rate=sample_rate))
        self._publish_status(force=True)

    def _start(self, message: dict[str, Any]) -> None:
        agent = self._require_agent()
        activation_id = message.get("activation_id")
        wake = message.get("wake")
        sample_rate = message.get("sample_rate")
        route_id = message.get("route_id", "default")
        if not isinstance(activation_id, str) or not isinstance(wake, dict):
            raise ValueError("start requires activation and wake metadata")
        if not isinstance(sample_rate, int) or sample_rate <= 0:
            raise ValueError("start requires a positive sample rate")
        if not isinstance(route_id, str) or not route_id:
            raise ValueError("start requires a route ID")
        phrase = wake.get("phrase")
        detected_at_ns = wake.get("detected_at_ns")
        trigger_id = wake.get("trigger_id")
        if not isinstance(phrase, str) or not isinstance(detected_at_ns, int):
            raise ValueError("wake metadata is invalid")
        if trigger_id is not None and not isinstance(trigger_id, str):
            raise ValueError("wake trigger ID is invalid")
        initial_audio = decode_float_audio(message.get("initial_audio"))
        self._controller.finish()
        self._controller.begin()
        self._activation_id = activation_id
        agent.start(
            DelegateStartContext(
                wake=WakeEvent(phrase, detected_at_ns, trigger_id=trigger_id),
                conversation=self._controller.handle,
                sample_rate=sample_rate,
                initial_audio=initial_audio,
                route_id=route_id,
            )
        )
        self._writer.emit("started", activation_id=activation_id)

    def _audio(self, message: dict[str, Any]) -> None:
        agent = self._require_active_agent(message)
        sample_rate = message.get("sample_rate")
        if not isinstance(sample_rate, int) or sample_rate <= 0:
            raise ValueError("audio requires a positive sample rate")
        agent.send_audio(decode_float_audio(message.get("audio")), sample_rate)

    def _request_end(self, message: dict[str, Any]) -> None:
        agent = self._require_active_agent(message)
        try:
            source = EndSource(message.get("source"))
            mode = EndMode(message.get("mode"))
        except ValueError as error:
            raise ValueError("end request source or mode is invalid") from error
        farewell = message.get("farewell")
        agent.request_end(
            EndConversationRequest(
                source=source,
                reason=str(message.get("reason", "requested"))[:200],
                mode=mode,
                requested_at_ns=time.monotonic_ns(),
                farewell=farewell[:240] if isinstance(farewell, str) else None,
            )
        )

    def _stop(self, message: dict[str, Any]) -> None:
        agent = self._require_active_agent(message)
        agent.stop()
        self._finish_activation(reason="stopped")

    def _require_agent(self) -> OpenAIRealtimeAgent:
        if self._agent is None:
            raise ValueError("delegate has not been prepared")
        return self._agent

    def _require_active_agent(self, message: dict[str, Any]) -> OpenAIRealtimeAgent:
        agent = self._require_agent()
        if message.get("activation_id") != self._activation_id:
            raise ValueError("message refers to a stale activation")
        return agent

    def _finish_activation(self, *, reason: str) -> None:
        activation_id = self._activation_id
        if activation_id is None:
            return
        self._activation_id = None
        self._controller.finish()
        self._writer.emit("ended", activation_id=activation_id, reason=reason)

    def _publish_status(self, *, force: bool = False) -> None:
        agent = self._agent
        if agent is None:
            return
        status = agent.status
        snapshot = (
            status.health,
            status.accepting_activation,
            status.warm,
            status.detail,
        )
        if not force and snapshot == self._last_status:
            return
        self._last_status = snapshot
        self._writer.emit(
            "status",
            health=status.health,
            accepting_activation=status.accepting_activation,
            warm=status.warm,
            detail=status.detail,
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-openai-delegate")
    parser.add_argument("--model", default="gpt-realtime-2.1")
    parser.add_argument("--voice", default="marin")
    parser.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    parser.add_argument("--output-device")
    parser.add_argument("--session-timeout", type=float, default=30.0)
    parser.add_argument(
        "--full-duplex",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    parser.add_argument(
        "--preconnect",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    parser.add_argument(
        "--realtime-vad",
        choices=("server_vad", "semantic_vad"),
        default="server_vad",
    )
    parser.add_argument("--vad-threshold", type=float, default=0.5)
    parser.add_argument("--vad-prefix-ms", type=int, default=300)
    parser.add_argument("--vad-silence-ms", type=int, default=300)
    parser.add_argument(
        "--vad-eagerness",
        choices=("low", "medium", "high", "auto"),
        default="high",
    )
    parser.add_argument(
        "--computer-use",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Expose the supervised macOS computer tool to the voice agent.",
    )
    parser.add_argument("--computer-model", default="gpt-5.4-mini")
    parser.add_argument(
        "--computer-max-task-cost-usd",
        type=float,
        default=DEFAULT_MAX_TASK_COST_USD,
        help=(
            "Hard estimated model-cost ceiling for one computer task "
            f"(default: ${DEFAULT_MAX_TASK_COST_USD:.2f}; use 0 to disable)."
        ),
    )
    parser.add_argument(
        "--computer-allow-app",
        action="append",
        default=None,
        help=(
            "Allowed macOS app name; repeat to add apps "
            "(default: TextEdit and Google Chrome)."
        ),
    )
    parser.add_argument(
        "--peekaboo-command",
        default="peekaboo mcp serve",
        help="Shell-style argv for the Peekaboo MCP server.",
    )
    return parser


def run(args: argparse.Namespace, *, input_stream: TextIO = sys.stdin) -> int:
    writer = ProtocolWriter()
    output_device: int | str | None = args.output_device
    if isinstance(output_device, str) and output_device.isdigit():
        output_device = int(output_device)

    def create_agent(
        logger: BridgeLogger,
        controller: ConversationController,
        player: AudioPlayback | None,
    ) -> OpenAIRealtimeAgent:
        computer_tool = None
        if args.computer_use:
            allowed_applications = frozenset(
                args.computer_allow_app or ["TextEdit", "Google Chrome"]
            )
            computer_tool = PeekabooTaskRunner(
                logger,  # type: ignore[arg-type]
                api_key=os.environ.get("OPENAI_API_KEY", ""),
                model=args.computer_model,
                max_task_cost_usd=(
                    args.computer_max_task_cost_usd
                    if args.computer_max_task_cost_usd != 0
                    else None
                ),
                command=tuple(shlex.split(args.peekaboo_command)),
                allowed_applications=allowed_applications,
            )
        return OpenAIRealtimeAgent(
            logger,  # type: ignore[arg-type]
            api_key=os.environ.get("OPENAI_API_KEY", ""),
            model=args.model,
            voice=args.voice,
            instructions=args.instructions,
            output_device=output_device,
            inactivity_timeout_seconds=args.session_timeout,
            full_duplex=args.full_duplex,
            preconnect=args.preconnect,
            vad_mode=args.realtime_vad,
            vad_threshold=args.vad_threshold,
            vad_prefix_padding_ms=args.vad_prefix_ms,
            vad_silence_duration_ms=args.vad_silence_ms,
            vad_eagerness=args.vad_eagerness,
            conversation_controller=controller,
            player=player,
            computer_tool=computer_tool,
        )

    worker = OpenAIProcessWorker(writer, create_agent)
    messages: queue.Queue[object | None] = queue.Queue()

    def read_input() -> None:
        for line in input_stream:
            if len(line.encode("utf-8")) > MAX_PROTOCOL_LINE_BYTES:
                messages.put(ValueError("protocol message exceeds maximum size"))
                return
            try:
                messages.put(json.loads(line))
            except json.JSONDecodeError as error:
                messages.put(error)
                return
        messages.put(None)

    reader = threading.Thread(target=read_input, name="wake-on-openai-stdin", daemon=True)
    reader.start()
    running = True
    try:
        while running:
            try:
                message = messages.get(timeout=0.01)
            except queue.Empty:
                message = ...
            if message is None:
                break
            if isinstance(message, BaseException):
                raise message
            if message is not ...:
                running = worker.handle(message)
            worker.poll()
    except BaseException as error:
        writer.emit(
            "status",
            health="failed",
            accepting_activation=False,
            warm=False,
            detail=str(error)[:500],
        )
        traceback.print_exc(file=sys.stderr)
        return_code = 1
    else:
        return_code = 0
    finally:
        worker.close()
        writer.close()
    return return_code


def main() -> None:
    load_dotenv()
    raise SystemExit(run(build_parser().parse_args()))


if __name__ == "__main__":
    main()
