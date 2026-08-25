from __future__ import annotations

import base64
import json
import threading
import time
from collections import deque
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
from .conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from .events import EventLogger
from .peekaboo_task import ComputerToolEvent, PeekabooTaskRunner
from .playback import AudioPlayback, AudioPlayer, ConversationCapture, PlaybackPosition
from .ring_buffer import FloatAudio

REALTIME_SAMPLE_RATE = 24_000
DEFAULT_INSTRUCTIONS = (
    "You are Lobby, a concise and friendly voice assistant. "
    "Respond naturally and briefly unless the user asks for detail. "
    "The user may begin by saying your wake phrase, Hey Lobby. "
    "Call end_conversation when the user explicitly asks to stop or says goodbye. "
    "You may also call it when a clearly delegated task is fully complete. "
    "Do not end merely because you answered one ordinary conversational turn. "
    "When ending, use only a quick send-off such as 'Thanks', 'Bye-bye', or "
    "'Have a nice day'. Do not recap, linger, offer more help, or give a ceremonial sign-off."
)
COMPUTER_INSTRUCTIONS = (
    " When the user asks you to inspect or operate an allowed macOS app, call use_computer "
    "with their complete task and the exact application name. Immediately before the tool call, "
    "say only a brief handoff such as, 'I'll kick off a task for that.' Do not explain the plan "
    "or repeat the request. A successful tool acknowledgement is silent; do not acknowledge it "
    "again. If task startup is rejected or fails, explain that briefly. Do not claim success "
    "until a later system task-result message confirms completion. Use "
    "steer_computer_task when the user changes the goal while that task is running, and use "
    "cancel_computer_task only when the user asks to stop it entirely. "
    "Unrelated conversation does not cancel background computer work."
)


def computer_scope_instructions(
    applications: tuple[str, ...],
    tools: tuple[str, ...],
) -> str:
    application_list = ", ".join(applications) or "none"
    tool_list = ", ".join(tools) or "none"
    return (
        f" The approved target applications are: {application_list}."
        f" The computer worker has these operations: {tool_list}."
        " A task naming another target application will be denied; say so plainly instead of"
        " implying broader access. The exposed operation catalog is authoritative. These"
        " limits describe available capability, not user authorization:"
        " only operate the computer when the user asks."
    )
END_CONVERSATION_TOOL = {
    "type": "function",
    "name": "end_conversation",
    "description": (
        "Request that the wake-word harness end the active voice conversation. "
        "Use when the user explicitly asks to stop or says goodbye, or when a clearly "
        "delegated task is fully complete. Do not use after every ordinary answer."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "reason": {
                "type": "string",
                "enum": ["user_requested", "task_complete", "cancelled"],
            },
            "farewell": {
                "type": "string",
                "maxLength": 40,
                "description": "An optional casual closing phrase of one to four words.",
            },
        },
        "required": ["reason"],
        "additionalProperties": False,
    },
}
USE_COMPUTER_TOOL = {
    "type": "function",
    "name": "use_computer",
    "description": (
        "Perform one bounded task in an allowed macOS application. Use this only when the "
        "user asks you to inspect or operate their computer. This returns immediately with a "
        "task ID while the task continues in the background. A verified result arrives later."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task": {"type": "string", "description": "The user's complete computer task."},
            "application": {
                "type": "string",
                "description": "The exact macOS application to operate.",
            },
        },
        "required": ["task", "application"],
        "additionalProperties": False,
    },
}


def build_use_computer_tool(
    applications: tuple[str, ...],
    tools: tuple[str, ...],
) -> dict[str, Any]:
    application_list = ", ".join(applications)
    tool_list = ", ".join(tools)
    return {
        "type": "function",
        "name": "use_computer",
        "description": (
            "Perform one bounded task in an allowed macOS application. This returns "
            "immediately with a task ID while the task continues in the background. "
            f"Allowed applications: {application_list}. Available operations: {tool_list}."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "The user's complete computer task within the listed scope.",
                },
                "application": {
                    "type": "string",
                    "enum": list(applications),
                    "description": "The exact allowed macOS application to operate.",
                },
            },
            "required": ["task", "application"],
            "additionalProperties": False,
        },
    }
CANCEL_COMPUTER_TASK_TOOL = {
    "type": "function",
    "name": "cancel_computer_task",
    "description": (
        "Cancel the active background computer task without ending the voice conversation. "
        "Use only when the user explicitly asks to stop, cancel, or replace that task."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task_id": {
                "type": "string",
                "description": "The task ID returned by use_computer; omit for the active task.",
            }
        },
        "required": [],
        "additionalProperties": False,
    },
}
STEER_COMPUTER_TASK_TOOL = {
    "type": "function",
    "name": "steer_computer_task",
    "description": (
        "Update the goal of the active background computer task without stopping the voice "
        "conversation. Use when the user corrects, redirects, or adds to the current goal. "
        "The existing task ID remains active. To change target applications, cancel and start "
        "a new task instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "instruction": {
                "type": "string",
                "description": "The user's new authoritative goal or correction.",
            },
            "task_id": {
                "type": "string",
                "description": "The task ID returned by use_computer; omit for the active task.",
            },
        },
        "required": ["instruction"],
        "additionalProperties": False,
    },
}
GRACEFUL_END_TIMEOUT_NS = 5_000_000_000
COMPUTER_NOTIFICATION_VOICE_GRACE_NS = 750_000_000
COMPUTER_SLOW_REASSURANCE_NS = 10_000_000_000


def resample_audio(samples: FloatAudio, source_rate: int, target_rate: int) -> FloatAudio:
    """Resample a small mono chunk using linear interpolation."""
    samples = np.asarray(samples, dtype=np.float32)
    if samples.size == 0 or source_rate == target_rate:
        return samples
    target_size = max(1, round(samples.size * target_rate / source_rate))
    source_positions = np.arange(samples.size, dtype=np.float64)
    target_positions = np.arange(target_size, dtype=np.float64) * source_rate / target_rate
    return np.interp(target_positions, source_positions, samples).astype(np.float32)


def float_audio_to_pcm16(
    samples: FloatAudio,
    source_rate: int,
    target_rate: int = REALTIME_SAMPLE_RATE,
) -> bytes:
    resampled = resample_audio(samples, source_rate, target_rate)
    clipped = np.clip(resampled, -1.0, 1.0)
    return (clipped * 32767).astype("<i2").tobytes()


def build_session_update(
    model: str,
    voice: str,
    instructions: str,
    *,
    vad_mode: str = "server_vad",
    vad_threshold: float = 0.5,
    vad_prefix_padding_ms: int = 300,
    vad_silence_duration_ms: int = 300,
    vad_eagerness: str = "high",
    computer_enabled: bool = False,
    computer_applications: tuple[str, ...] = (),
    computer_tools: tuple[str, ...] = (),
) -> dict[str, Any]:
    if vad_mode == "server_vad":
        turn_detection: dict[str, Any] = {
            "type": "server_vad",
            "threshold": vad_threshold,
            "prefix_padding_ms": vad_prefix_padding_ms,
            "silence_duration_ms": vad_silence_duration_ms,
            "create_response": True,
            "interrupt_response": True,
        }
    elif vad_mode == "semantic_vad":
        turn_detection = {
            "type": "semantic_vad",
            "eagerness": vad_eagerness,
            "create_response": True,
            "interrupt_response": True,
        }
    else:
        raise ValueError("vad_mode must be 'server_vad' or 'semantic_vad'")
    computer_tool = (
        build_use_computer_tool(computer_applications, computer_tools)
        if computer_enabled and computer_applications
        else USE_COMPUTER_TOOL
    )
    return {
        "type": "session.update",
        "session": {
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "tools": [
                END_CONVERSATION_TOOL,
                *(
                    [computer_tool, STEER_COMPUTER_TASK_TOOL, CANCEL_COMPUTER_TASK_TOOL]
                    if computer_enabled
                    else []
                ),
            ],
            "tool_choice": "auto",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": REALTIME_SAMPLE_RATE},
                    "turn_detection": turn_detection,
                },
                "output": {
                    "format": {"type": "audio/pcm", "rate": REALTIME_SAMPLE_RATE},
                    "voice": voice,
                },
            },
        },
    }


class OpenAIRealtimeAgent:
    """Streams microphone audio to an OpenAI Realtime WebSocket session."""

    def __init__(
        self,
        logger: EventLogger,
        *,
        api_key: str,
        model: str = "gpt-realtime-2.1",
        voice: str = "marin",
        instructions: str = DEFAULT_INSTRUCTIONS,
        output_device: int | str | None = None,
        inactivity_timeout_seconds: float = 30.0,
        full_duplex: bool = True,
        preconnect: bool = True,
        vad_mode: str = "server_vad",
        vad_threshold: float = 0.5,
        vad_prefix_padding_ms: int = 300,
        vad_silence_duration_ms: int = 300,
        vad_eagerness: str = "high",
        conversation_controller: ConversationController | None = None,
        player: AudioPlayback | None = None,
        audio_input: AudioInputOwnership = AudioInputOwnership.HARNESS,
        capture: ConversationCapture | None = None,
        computer_tool: PeekabooTaskRunner | None = None,
    ) -> None:
        if not api_key:
            raise ValueError("OPENAI_API_KEY is not set")
        self._logger = logger
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._instructions = instructions
        self._timeout_ns = round(inactivity_timeout_seconds * 1_000_000_000)
        self._full_duplex = full_duplex
        self._preconnect = preconnect
        self._vad_mode = vad_mode
        self._vad_threshold = vad_threshold
        self._vad_prefix_padding_ms = vad_prefix_padding_ms
        self._vad_silence_duration_ms = vad_silence_duration_ms
        self._vad_eagerness = vad_eagerness
        self._conversation = conversation_controller or ConversationController(logger)
        self._player = player or AudioPlayer(device=output_device)
        self._audio_input = audio_input
        self._capture = capture
        self._computer_tool = computer_tool
        self._computer_task_activations: dict[str, int] = {}
        self._computer_task_started_ns: dict[str, int] = {}
        self._computer_task_slow_notified: set[str] = set()
        self._computer_silent_terminal_tasks: set[str] = set()
        self._pending_computer_notifications: deque[ComputerToolEvent] = deque()
        self._activation_generation = 0
        self._user_speaking = False
        self._voice_priority_until_ns = 0
        self._pending_audio: deque[bytes] = deque(maxlen=500)
        self._send_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._ws = None
        self._thread: threading.Thread | None = None
        self._reconnect_timer: threading.Timer | None = None
        self._prepared = False
        self._closing = False
        self._connecting = False
        self._active = False
        self._ready = False
        self._connection_started_at_ns: int | None = None
        self._ready_at_ns: int | None = None
        self._started_at_ns: int | None = None
        self._last_activity_ns: int | None = None
        self._first_response_received = False
        self._first_response_played = False
        self._first_input_audio_sent = False
        self._wake_detected_at_ns: int | None = None
        self._response_active = False
        self._ending = False
        self._end_request: EndConversationRequest | None = None
        self._closing_response_requested = False
        self._closing_response_done = False
        self._end_deadline_ns: int | None = None
        self._transcript_parts: list[str] = []
        self._active_output_item_id: str | None = None
        self._active_output_content_index = 0
        self._interrupted_output_items: set[str] = set()

    @property
    def active(self) -> bool:
        return self._active

    @property
    def capabilities(self) -> DelegateCapabilities:
        return DelegateCapabilities(audio_input=self._audio_input)

    @property
    def status(self) -> DelegateStatus:
        with self._state_lock:
            if self._closing:
                return DelegateStatus(DelegateHealth.CLOSED, accepting_activation=False)
            if not self._prepared:
                return DelegateStatus(DelegateHealth.CREATED, accepting_activation=False)
            return DelegateStatus(
                DelegateHealth.READY,
                accepting_activation=True,
                warm=self._ready and self._ws is not None,
                detail="preconnecting" if self._preconnect and not self._ready else None,
            )

    def prepare(self, context: DelegatePrepareContext) -> None:
        del context
        self._player.start()
        if self._computer_tool is not None:
            self._computer_tool.prepare()
        self._prepared = True
        self._logger.emit(
            "delegate.prepared",
            adapter="openai_realtime",
            model=self._model,
            voice=self._voice,
            full_duplex=self._full_duplex,
            preconnect=self._preconnect,
            vad_mode=self._vad_mode,
            vad_threshold=self._vad_threshold if self._vad_mode == "server_vad" else None,
            vad_prefix_padding_ms=(
                self._vad_prefix_padding_ms if self._vad_mode == "server_vad" else None
            ),
            vad_silence_duration_ms=(
                self._vad_silence_duration_ms if self._vad_mode == "server_vad" else None
            ),
            vad_eagerness=self._vad_eagerness if self._vad_mode == "semantic_vad" else None,
            audio_input=self._audio_input,
        )
        if self._preconnect:
            self._logger.emit("agent.preconnection_started", adapter="openai_realtime")
            self._ensure_connection()

    def start(self, context: DelegateStartContext) -> None:
        if self._active:
            return
        if context.initial_audio is None and self._audio_input is AudioInputOwnership.HARNESS:
            raise ValueError("OpenAIRealtimeAgent requires harness-owned input audio")
        initial_audio = context.initial_audio
        sample_rate = context.sample_rate
        wake = context.wake
        now_ns = time.monotonic_ns()
        self._activation_generation += 1
        initial_pcm16 = (
            float_audio_to_pcm16(initial_audio, sample_rate) if initial_audio is not None else None
        )
        with self._state_lock:
            connection_ready = self._ready and self._ws is not None
            ready_at_ns = self._ready_at_ns
            self._active = True
            self._started_at_ns = now_ns
            self._last_activity_ns = now_ns
            self._first_response_received = False
            self._first_response_played = False
            self._first_input_audio_sent = False
            self._wake_detected_at_ns = wake.detected_at_ns
            self._response_active = False
            self._user_speaking = False
            self._voice_priority_until_ns = 0
            self._ending = False
            self._end_request = None
            self._closing_response_requested = False
            self._closing_response_done = False
            self._end_deadline_ns = None
            self._transcript_parts.clear()
            self._active_output_item_id = None
            self._active_output_content_index = 0
            self._interrupted_output_items.clear()
            self._pending_audio.clear()
            if not connection_ready and initial_pcm16 is not None:
                self._pending_audio.append(initial_pcm16)
        self._logger.emit(
            "agent.started",
            adapter="openai_realtime",
            route_id=context.route_id,
            wake_phrase=wake.phrase,
            wake_to_agent_start_ms=(now_ns - wake.detected_at_ns) / 1_000_000,
            initial_audio_ms=(
                initial_audio.size / sample_rate * 1000 if initial_audio is not None else 0
            ),
        )
        if connection_ready:
            self._logger.emit(
                "agent.connection_reused",
                adapter="openai_realtime",
                wake_to_connection_ready_ms=(time.monotonic_ns() - now_ns) / 1_000_000,
                preconnected_for_ms=(
                    (now_ns - ready_at_ns) / 1_000_000 if ready_at_ns is not None else 0
                ),
            )
            if initial_pcm16 is not None and not self._send_audio(initial_pcm16):
                with self._state_lock:
                    self._pending_audio.appendleft(initial_pcm16)
                self._ensure_connection()
        else:
            self._ensure_connection()
        # Send or queue the harness preroll before a delegate-owned capture
        # device performs a potentially slow raw-to-AEC transition. This keeps
        # backend processing overlapped with media setup and preserves ordering
        # before the first live conversation frame.
        if self._capture is not None:
            self._capture.activate_capture()

    def send_audio(self, samples: FloatAudio, sample_rate: int) -> None:
        if not self._active:
            return
        if not self._full_duplex and self._player.playing:
            return
        pcm16 = float_audio_to_pcm16(samples, sample_rate)
        with self._state_lock:
            if not self._ready:
                self._pending_audio.append(pcm16)
                return
        if not self._send_audio(pcm16):
            with self._state_lock:
                self._pending_audio.append(pcm16)

    def poll(self) -> None:
        self._poll_computer_events()
        if self._ending:
            if self._closing_response_done and not self._player.playing:
                self.stop()
                return
            if self._end_deadline_ns is not None and time.monotonic_ns() >= self._end_deadline_ns:
                self._logger.emit(
                    "agent.graceful_end_timeout",
                    adapter="openai_realtime",
                )
                self.stop()
            return
        if not self._active or self._last_activity_ns is None:
            return
        self._flush_computer_notification()
        if time.monotonic_ns() - self._last_activity_ns >= self._timeout_ns:
            self._logger.emit(
                "agent.inactivity_timeout",
                adapter="openai_realtime",
                timeout_ms=self._timeout_ns / 1_000_000,
            )
            self.stop()

    def request_end(self, request: EndConversationRequest) -> None:
        self._logger.emit(
            "agent.end_requested",
            adapter="openai_realtime",
            source=request.source,
            reason=request.reason,
            mode=request.mode,
        )
        self._cancel_active_computer(reason="voice_conversation_ending", suppress_result=True)
        if request.mode is EndMode.IMMEDIATE:
            self.stop()
            return
        if self._ending:
            return
        self._ending = True
        self._end_request = request
        self._closing_response_requested = False
        self._closing_response_done = False
        self._end_deadline_ns = time.monotonic_ns() + GRACEFUL_END_TIMEOUT_NS
        if not self._response_active:
            self._begin_graceful_close()

    def stop(self) -> None:
        self._cancel_active_computer(reason="voice_conversation_stopped", suppress_result=True)
        self._computer_task_activations.clear()
        self._computer_task_started_ns.clear()
        self._computer_task_slow_notified.clear()
        self._pending_computer_notifications.clear()
        if self._capture is not None:
            self._capture.deactivate_capture()
        with self._state_lock:
            was_active = self._active
            started_at_ns = self._started_at_ns
            self._active = False
            self._ready = False
            self._ready_at_ns = None
            self._pending_audio.clear()
            ws, self._ws = self._ws, None
            self._response_active = False
            self._user_speaking = False
            self._voice_priority_until_ns = 0
            self._ending = False
            self._end_request = None
            self._closing_response_requested = False
            self._closing_response_done = False
            self._end_deadline_ns = None
            self._active_output_item_id = None
            self._active_output_content_index = 0
            self._interrupted_output_items.clear()
        self._player.clear()
        if was_active:
            self._logger.emit(
                "agent.stopped",
                adapter="openai_realtime",
                duration_ms=(
                    (time.monotonic_ns() - started_at_ns) / 1_000_000
                    if started_at_ns is not None
                    else 0
                ),
            )
        self._started_at_ns = None
        if was_active and self._prepared and self._preconnect and not self._closing:
            self._schedule_reconnect(reason="session_reset")
        if ws is not None:
            ws.close()

    def close(self) -> None:
        self._closing = True
        self._prepared = False
        if self._reconnect_timer is not None:
            self._reconnect_timer.cancel()
            self._reconnect_timer = None
        self.stop()
        if self._computer_tool is not None:
            self._computer_tool.close()
        self._player.close()

    def _ensure_connection(self) -> None:
        with self._state_lock:
            if self._closing or self._connecting or self._ready:
                return
            self._connecting = True
            self._connection_started_at_ns = time.monotonic_ns()
        self._thread = threading.Thread(
            target=self._connect,
            name="lobby-realtime-websocket",
            daemon=True,
        )
        self._thread.start()

    def _connect(self) -> None:
        import websocket

        url = f"wss://api.openai.com/v1/realtime?model={self._model}"
        ws = websocket.WebSocketApp(
            url,
            header={"Authorization": f"Bearer {self._api_key}"},
            on_open=self._on_open,
            on_message=self._on_message,
            on_error=self._on_error,
            on_close=self._on_close,
        )
        with self._state_lock:
            if self._closing:
                self._connecting = False
                return
            self._ws = ws
        try:
            ws.run_forever()
        finally:
            with self._state_lock:
                if self._ws is ws:
                    self._ws = None
                    self._ready = False
                    self._ready_at_ns = None
                self._connecting = False
                should_reconnect = self._prepared and self._preconnect and not self._closing
            if should_reconnect:
                self._schedule_reconnect(reason="connection_closed")

    def _on_open(self, ws: Any) -> None:
        instructions = self._instructions
        computer_applications: tuple[str, ...] = ()
        computer_tools: tuple[str, ...] = ()
        if self._computer_tool is not None:
            computer_applications = self._computer_tool.allowed_applications
            computer_tools = self._computer_tool.available_tools
            instructions += COMPUTER_INSTRUCTIONS + computer_scope_instructions(
                computer_applications,
                computer_tools,
            )
        self._send_event(
            build_session_update(
                self._model,
                self._voice,
                instructions,
                vad_mode=self._vad_mode,
                vad_threshold=self._vad_threshold,
                vad_prefix_padding_ms=self._vad_prefix_padding_ms,
                vad_silence_duration_ms=self._vad_silence_duration_ms,
                vad_eagerness=self._vad_eagerness,
                computer_enabled=self._computer_tool is not None,
                computer_applications=computer_applications,
                computer_tools=computer_tools,
            ),
            ws,
        )

    def _on_message(self, ws: Any, raw_message: str) -> None:
        if ws is not self._ws:
            return
        try:
            event = json.loads(raw_message)
        except json.JSONDecodeError:
            self._logger.emit("agent.protocol_error", detail="invalid JSON from Realtime API")
            return

        event_type = event.get("type")
        if event_type == "session.updated":
            now_ns = time.monotonic_ns()
            with self._state_lock:
                self._ready = True
                self._ready_at_ns = now_ns
                pending = list(self._pending_audio)
                self._pending_audio.clear()
                active = self._active
                connection_started_at_ns = self._connection_started_at_ns
            connection_setup_ms = (
                (now_ns - connection_started_at_ns) / 1_000_000
                if connection_started_at_ns is not None
                else 0
            )
            if active:
                self._last_activity_ns = now_ns
                self._logger.emit(
                    "agent.connection_ready",
                    adapter="openai_realtime",
                    wake_to_connection_ready_ms=(
                        (now_ns - self._started_at_ns) / 1_000_000
                        if self._started_at_ns is not None
                        else 0
                    ),
                    connection_setup_ms=connection_setup_ms,
                    buffered_chunks=len(pending),
                )
            else:
                self._logger.emit(
                    "agent.preconnection_ready",
                    adapter="openai_realtime",
                    connection_setup_ms=connection_setup_ms,
                )
            for pcm16 in pending:
                self._send_audio(pcm16)
        elif event_type == "response.created":
            self._response_active = True
            self._active_output_item_id = None
            self._active_output_content_index = 0
        elif event_type == "input_audio_buffer.speech_started":
            self._user_speaking = True
            self._last_activity_ns = time.monotonic_ns()
            speech_started_at_ns = self._logger.emit(
                "agent.user_speech_started",
                audio_start_ms=event.get("audio_start_ms"),
                item_id=event.get("item_id"),
                vad_mode=self._vad_mode,
            )
            self._interrupt_response_playback(speech_started_at_ns)
        elif event_type == "input_audio_buffer.speech_stopped":
            self._user_speaking = False
            self._voice_priority_until_ns = (
                time.monotonic_ns() + COMPUTER_NOTIFICATION_VOICE_GRACE_NS
            )
            self._last_activity_ns = time.monotonic_ns()
            self._logger.emit(
                "agent.user_speech_stopped",
                audio_end_ms=event.get("audio_end_ms"),
                item_id=event.get("item_id"),
                vad_mode=self._vad_mode,
            )
        elif event_type == "response.output_audio.delta":
            self._handle_audio_delta(event)
        elif event_type == "conversation.item.truncated":
            self._logger.emit(
                "agent.item_truncation_confirmed",
                item_id=event.get("item_id"),
                content_index=event.get("content_index"),
                audio_end_ms=event.get("audio_end_ms"),
            )
        elif event_type == "response.output_audio_transcript.delta":
            self._transcript_parts.append(event.get("delta", ""))
        elif event_type == "response.output_audio_transcript.done":
            transcript = event.get("transcript") or "".join(self._transcript_parts)
            self._transcript_parts.clear()
            self._logger.emit("agent.response_transcript", transcript=transcript)
        elif event_type == "response.done":
            self._response_active = False
            self._last_activity_ns = time.monotonic_ns()
            response = event.get("response", {})
            status = response.get("status")
            metadata = response.get("metadata") or {}
            self._logger.emit(
                "agent.response_done",
                status=status,
                purpose=metadata.get("purpose"),
            )
            if metadata.get("purpose") == "conversation_close":
                self._closing_response_done = True
            else:
                self._handle_function_calls(response.get("output") or [])
                if self._ending and not self._closing_response_requested:
                    self._begin_graceful_close()
        elif event_type == "error":
            error = event.get("error", {})
            self._logger.emit(
                "agent.api_error",
                error_type=error.get("type"),
                code=error.get("code"),
                detail=error.get("message"),
            )

    def _handle_audio_delta(self, event: dict[str, Any]) -> None:
        item_id = event.get("item_id")
        content_index = event.get("content_index")
        if not isinstance(item_id, str) or not isinstance(content_index, int):
            self._logger.emit(
                "agent.protocol_error",
                detail="output audio delta missing item_id or content_index",
            )
            return
        if item_id in self._interrupted_output_items:
            return
        try:
            pcm16 = base64.b64decode(event["delta"])
        except (KeyError, ValueError):
            self._logger.emit("agent.protocol_error", detail="invalid output audio delta")
            return
        self._last_activity_ns = time.monotonic_ns()
        self._active_output_item_id = item_id
        self._active_output_content_index = content_index
        if not self._first_response_received:
            self._first_response_received = True
            received_ns = time.monotonic_ns()
            self._logger.emit(
                "agent.first_response_received",
                wake_to_response_ms=(
                    (received_ns - self._started_at_ns) / 1_000_000
                    if self._started_at_ns is not None
                    else 0
                ),
            )
        self._player.enqueue(
            pcm16,
            self._mark_first_playback,
            item_id=item_id,
            content_index=content_index,
        )

    def _interrupt_response_playback(self, speech_started_at_ns: int) -> None:
        item_id = self._active_output_item_id
        if item_id is None or not (self._response_active or self._player.playing):
            return
        content_index = self._active_output_content_index
        self._interrupted_output_items.add(item_id)
        position = self._player.interrupt(item_id, content_index)
        playback_stopped_at_ns = time.monotonic_ns()
        if position is None:
            position = PlaybackPosition(item_id, content_index, 0)
        self._logger.emit(
            "agent.playback_interrupted",
            item_id=position.item_id,
            content_index=position.content_index,
            audio_end_ms=position.audio_end_ms,
            vad_to_playback_stop_ms=(playback_stopped_at_ns - speech_started_at_ns) / 1_000_000,
        )
        if self._send_event(
            {
                "type": "conversation.item.truncate",
                "item_id": position.item_id,
                "content_index": position.content_index,
                "audio_end_ms": position.audio_end_ms,
            }
        ):
            self._logger.emit(
                "agent.item_truncation_sent",
                item_id=position.item_id,
                content_index=position.content_index,
                audio_end_ms=position.audio_end_ms,
            )

    def _mark_first_playback(self) -> None:
        if self._first_response_played:
            return
        self._first_response_played = True
        played_ns = time.monotonic_ns()
        self._logger.emit(
            "agent.first_response_played",
            wake_to_playback_ms=(
                (played_ns - self._started_at_ns) / 1_000_000
                if self._started_at_ns is not None
                else 0
            ),
        )

    def _handle_function_calls(self, output: list[dict[str, Any]]) -> None:
        for item in output:
            if item.get("type") != "function_call":
                continue
            if item.get("name") == "use_computer":
                self._start_computer_call(item)
                continue
            if item.get("name") == "cancel_computer_task":
                self._cancel_computer_call(item)
                continue
            if item.get("name") == "steer_computer_task":
                self._steer_computer_call(item)
                continue
            if item.get("name") != "end_conversation":
                continue
            try:
                arguments = json.loads(item.get("arguments") or "{}")
            except json.JSONDecodeError:
                arguments = {}
                self._logger.emit(
                    "agent.tool_arguments_error",
                    tool="end_conversation",
                )
            reason = arguments.get("reason", "user_requested")
            if reason not in {"user_requested", "task_complete", "cancelled"}:
                reason = "user_requested"
            farewell = arguments.get("farewell")
            if not isinstance(farewell, str):
                farewell = None
            elif len(farewell) > 240:
                farewell = farewell[:240]
            self._conversation.request_end(
                source=EndSource.MODEL,
                reason=reason,
                mode=EndMode.GRACEFUL,
                farewell=farewell,
                tool_call_id=item.get("call_id"),
            )

    def _start_computer_call(self, item: dict[str, Any]) -> None:
        call_id = item.get("call_id")
        if not isinstance(call_id, str):
            self._logger.emit("agent.tool_arguments_error", tool="use_computer")
            return
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        task = arguments.get("task")
        application = arguments.get("application")
        if (
            self._computer_tool is None
            or not isinstance(task, str)
            or not task.strip()
            or not isinstance(application, str)
            or not application.strip()
        ):
            self._finish_computer_call(
                call_id,
                {"status": "invalid_request", "summary": "Computer tool arguments are invalid."},
                purpose="computer_task_rejected",
            )
            return
        try:
            result = self._computer_tool.start(task.strip(), application.strip())
        except Exception as error:
            result_output: dict[str, str] = {
                "status": "failed",
                "summary": str(error)[:500],
            }
        else:
            result_output = {"status": result.status, "summary": result.summary}
            if result.task_id is not None:
                result_output["task_id"] = result.task_id
                if result.status == "accepted":
                    self._computer_task_activations[result.task_id] = self._activation_generation
                    self._computer_task_started_ns[result.task_id] = time.monotonic_ns()
        self._logger.emit(
            "agent.computer_tool_started",
            application=application,
            task_id=result_output.get("task_id"),
            status=result_output["status"],
        )
        self._finish_computer_call(
            call_id,
            result_output,
            purpose=(
                "computer_task_accepted"
                if result_output["status"] == "accepted"
                else "computer_task_rejected"
            ),
            request_response=result_output["status"] != "accepted",
        )

    def _cancel_computer_call(self, item: dict[str, Any]) -> None:
        call_id = item.get("call_id")
        if not isinstance(call_id, str):
            self._logger.emit("agent.tool_arguments_error", tool="cancel_computer_task")
            return
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        task_id = arguments.get("task_id")
        if task_id is not None and not isinstance(task_id, str):
            task_id = None
        if self._computer_tool is None:
            output = {"status": "not_available", "summary": "Computer use is not enabled."}
        else:
            result = self._computer_tool.cancel(task_id, reason="model_requested")
            output = {"status": result.status, "summary": result.summary}
            if result.task_id is not None:
                output["task_id"] = result.task_id
                if result.status == "cancellation_requested":
                    self._computer_silent_terminal_tasks.add(result.task_id)
        self._logger.emit("agent.computer_tool_cancelled", **output)
        self._finish_computer_call(call_id, output, purpose="computer_task_cancel")

    def _steer_computer_call(self, item: dict[str, Any]) -> None:
        call_id = item.get("call_id")
        if not isinstance(call_id, str):
            self._logger.emit("agent.tool_arguments_error", tool="steer_computer_task")
            return
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        task_id = arguments.get("task_id")
        instruction = arguments.get("instruction")
        if task_id is not None and not isinstance(task_id, str):
            task_id = None
        if (
            self._computer_tool is None
            or not isinstance(instruction, str)
            or not instruction.strip()
        ):
            output = {
                "status": "invalid_request",
                "summary": "Computer task steering arguments are invalid.",
            }
        else:
            result = self._computer_tool.steer(task_id, instruction.strip())
            output = {"status": result.status, "summary": result.summary}
            if result.task_id is not None:
                output["task_id"] = result.task_id
        self._logger.emit("agent.computer_tool_steered", **output)
        self._finish_computer_call(call_id, output, purpose="computer_task_steer")

    def _finish_computer_call(
        self,
        call_id: str,
        output: dict[str, str],
        *,
        purpose: str,
        request_response: bool = True,
    ) -> None:
        if not self._send_event(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "function_call_output",
                    "call_id": call_id,
                    "output": json.dumps(output, separators=(",", ":")),
                },
            }
        ):
            return
        if not request_response:
            return
        response_requested = self._send_event(
            {
                "type": "response.create",
                "response": {"metadata": {"purpose": purpose}},
            }
        )
        if response_requested:
            self._response_active = True

    def _poll_computer_events(self) -> None:
        if self._computer_tool is None:
            return
        for event in self._computer_tool.poll_events():
            if not event.terminal:
                self._logger.emit(
                    "agent.computer_tool_progress",
                    task_id=event.task_id,
                    summary=event.summary,
                )
                continue
            activation = self._computer_task_activations.pop(event.task_id, None)
            self._computer_task_started_ns.pop(event.task_id, None)
            self._computer_task_slow_notified.discard(event.task_id)
            silent = event.task_id in self._computer_silent_terminal_tasks
            self._computer_silent_terminal_tasks.discard(event.task_id)
            self._logger.emit(
                "agent.computer_tool_finished",
                task_id=event.task_id,
                status=event.status,
                summary=event.summary,
                announced=not silent and activation == self._activation_generation,
            )
            if (
                not silent
                and activation == self._activation_generation
                and self._active
                and not self._ending
            ):
                self._pending_computer_notifications.append(event)

        now_ns = time.monotonic_ns()
        for task_id, started_ns in tuple(self._computer_task_started_ns.items()):
            if (
                task_id in self._computer_task_slow_notified
                or now_ns - started_ns < COMPUTER_SLOW_REASSURANCE_NS
                or self._computer_task_activations.get(task_id) != self._activation_generation
                or not self._active
                or self._ending
            ):
                continue
            self._computer_task_slow_notified.add(task_id)
            self._pending_computer_notifications.append(
                ComputerToolEvent(
                    task_id=task_id,
                    generation=0,
                    status="slow",
                    summary="The task is taking a bit. I'll check back on it in a while.",
                    terminal=False,
                )
            )
            self._logger.emit(
                "agent.computer_tool_slow_reassurance_queued",
                task_id=task_id,
                running_ms=(now_ns - started_ns) / 1_000_000,
            )

    def _flush_computer_notification(self) -> None:
        if (
            not self._pending_computer_notifications
            or self._user_speaking
            or self._response_active
            or self._player.playing
            or time.monotonic_ns() < self._voice_priority_until_ns
            or self._ending
            or not self._ready
        ):
            return
        event = self._pending_computer_notifications.popleft()
        status_message = json.dumps(
            {
                "source": "computer_task",
                "task_id": event.task_id,
                "status": event.status,
                "summary": event.summary,
            },
            separators=(",", ":"),
        )
        if not self._send_event(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "system",
                    "content": [{"type": "input_text", "text": status_message}],
                },
            }
        ):
            return
        notification_instruction = (
            "Say exactly: The task is taking a bit. I'll check back on it in a while. "
            "Do not add anything else or call a tool."
            if event.status == "slow"
            else (
                "Report this computer-task result in one brief, natural sentence. "
                "Do not interrupt a new user request, recap unrelated conversation, "
                "or call another tool unless the result requires recovery."
            )
        )
        response_requested = self._send_event(
            {
                "type": "response.create",
                "response": {
                    "instructions": notification_instruction,
                    "metadata": {
                        "purpose": "computer_task_notification",
                        "task_id": event.task_id,
                    },
                },
            }
        )
        if response_requested:
            self._response_active = True

    def _cancel_active_computer(self, *, reason: str, suppress_result: bool) -> None:
        if self._computer_tool is None:
            return
        result = self._computer_tool.cancel(reason=reason)
        if suppress_result and result.task_id is not None:
            self._computer_silent_terminal_tasks.add(result.task_id)

    def _begin_graceful_close(self) -> None:
        request = self._end_request
        if request is None or self._closing_response_requested:
            return
        if request.tool_call_id is not None:
            self._send_event(
                {
                    "type": "conversation.item.create",
                    "item": {
                        "type": "function_call_output",
                        "call_id": request.tool_call_id,
                        "output": json.dumps({"status": "ending"}),
                    },
                }
            )
        closing_instruction = (
            "Say only one quick send-off, then stop. Use 'Thanks', 'Bye-bye', or "
            "'Have a nice day'. Do not add any other words, recap, offer more help, "
            "ask a question, or call any tools."
        )
        if request.farewell:
            closing_instruction += (
                f" Use this closing message if it fits the limit; otherwise shorten it: "
                f"{request.farewell}"
            )
        self._closing_response_requested = self._send_event(
            {
                "type": "response.create",
                "response": {
                    "instructions": closing_instruction,
                    "output_modalities": ["audio"],
                    "tools": [],
                    "tool_choice": "none",
                    "metadata": {"purpose": "conversation_close"},
                },
            }
        )

    def _send_audio(self, pcm16: bytes) -> bool:
        sent = self._send_event(
            {
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(pcm16).decode("ascii"),
            }
        )
        if not sent:
            return False
        with self._state_lock:
            first_audio = self._active and not self._first_input_audio_sent
            if first_audio:
                self._first_input_audio_sent = True
                wake_detected_at_ns = self._wake_detected_at_ns
            else:
                wake_detected_at_ns = None
        if first_audio:
            self._logger.emit(
                "agent.first_audio_sent",
                wake_to_first_audio_sent_ms=(
                    (time.monotonic_ns() - wake_detected_at_ns) / 1_000_000
                    if wake_detected_at_ns is not None
                    else 0
                ),
            )
        return True

    def _send_event(self, event: dict[str, Any], ws: Any | None = None) -> bool:
        socket = ws or self._ws
        if socket is None:
            return False
        try:
            with self._send_lock:
                socket.send(json.dumps(event, separators=(",", ":")))
        except Exception as error:
            self._logger.emit("agent.send_error", detail=str(error))
            with self._state_lock:
                if self._ws is socket:
                    self._ready = False
                    self._ready_at_ns = None
            socket.close()
            return False
        return True

    def _on_error(self, ws: Any, error: object) -> None:
        if ws is not self._ws or self._closing:
            return
        self._logger.emit("agent.connection_error", detail=str(error))

    def _on_close(self, ws: Any, status_code: int | None, message: str | None) -> None:
        with self._state_lock:
            if ws is not self._ws:
                return
            was_active = self._active
            self._ready = False
            self._ready_at_ns = None
            self._ws = None
            if was_active:
                self._active = False
        if was_active:
            self._logger.emit(
                "agent.connection_closed",
                status_code=status_code,
                detail=message,
            )

    def _schedule_reconnect(self, *, reason: str) -> None:
        with self._state_lock:
            if self._closing:
                return
            if self._reconnect_timer is not None:
                return
            timer = threading.Timer(0.5, self._run_scheduled_reconnect)
            timer.daemon = True
            self._reconnect_timer = timer
            timer.start()
        self._logger.emit(
            "agent.preconnection_scheduled",
            reason=reason,
            retry_in_ms=500,
        )

    def _run_scheduled_reconnect(self) -> None:
        with self._state_lock:
            self._reconnect_timer = None
        self._ensure_connection()
