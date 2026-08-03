from __future__ import annotations

import base64
import json
import threading
import time
from collections import deque
from typing import Any

import numpy as np

from .agent import (
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
from .playback import AudioPlayer, PlaybackPosition
from .ring_buffer import FloatAudio

REALTIME_SAMPLE_RATE = 24_000
DEFAULT_INSTRUCTIONS = (
    "You are Lobby, a concise and friendly voice assistant. "
    "Respond naturally and briefly unless the user asks for detail. "
    "The user may begin by saying your wake phrase, Hey Lobby. "
    "Call end_conversation when the user explicitly asks to stop or says goodbye. "
    "You may also call it when a clearly delegated task is fully complete. "
    "Do not end merely because you answered one ordinary conversational turn."
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
                "description": "An optional short, natural closing sentence.",
            },
        },
        "required": ["reason"],
        "additionalProperties": False,
    },
}
GRACEFUL_END_TIMEOUT_NS = 5_000_000_000


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
    return {
        "type": "session.update",
        "session": {
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "tools": [END_CONVERSATION_TOOL],
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
        self._player = AudioPlayer(device=output_device)
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
        return DelegateCapabilities()

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
        )
        if self._preconnect:
            self._logger.emit("agent.preconnection_started", adapter="openai_realtime")
            self._ensure_connection()

    def start(self, context: DelegateStartContext) -> None:
        if self._active:
            return
        if context.initial_audio is None:
            raise ValueError("OpenAIRealtimeAgent requires harness-owned input audio")
        initial_audio = context.initial_audio
        sample_rate = context.sample_rate
        wake = context.wake
        now_ns = time.monotonic_ns()
        initial_pcm16 = float_audio_to_pcm16(initial_audio, sample_rate)
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
            if not connection_ready:
                self._pending_audio.append(initial_pcm16)
        self._logger.emit(
            "agent.started",
            adapter="openai_realtime",
            route_id=context.route_id,
            wake_phrase=wake.phrase,
            wake_to_agent_start_ms=(now_ns - wake.detected_at_ns) / 1_000_000,
            initial_audio_ms=initial_audio.size / sample_rate * 1000,
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
            if not self._send_audio(initial_pcm16):
                with self._state_lock:
                    self._pending_audio.appendleft(initial_pcm16)
                self._ensure_connection()
        else:
            self._ensure_connection()

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
        if self._ending:
            if self._closing_response_done and not self._player.playing:
                self.stop()
                return
            if (
                self._end_deadline_ns is not None
                and time.monotonic_ns() >= self._end_deadline_ns
            ):
                self._logger.emit(
                    "agent.graceful_end_timeout",
                    adapter="openai_realtime",
                )
                self.stop()
            return
        if not self._active or self._last_activity_ns is None:
            return
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
        with self._state_lock:
            was_active = self._active
            started_at_ns = self._started_at_ns
            self._active = False
            self._ready = False
            self._ready_at_ns = None
            self._pending_audio.clear()
            ws, self._ws = self._ws, None
            self._response_active = False
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
        self._send_event(
            build_session_update(
                self._model,
                self._voice,
                self._instructions,
                vad_mode=self._vad_mode,
                vad_threshold=self._vad_threshold,
                vad_prefix_padding_ms=self._vad_prefix_padding_ms,
                vad_silence_duration_ms=self._vad_silence_duration_ms,
                vad_eagerness=self._vad_eagerness,
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
            self._last_activity_ns = time.monotonic_ns()
            speech_started_at_ns = self._logger.emit(
                "agent.user_speech_started",
                audio_start_ms=event.get("audio_start_ms"),
                item_id=event.get("item_id"),
                vad_mode=self._vad_mode,
            )
            self._interrupt_response_playback(speech_started_at_ns)
        elif event_type == "input_audio_buffer.speech_stopped":
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
            "Say one brief, natural closing sentence, then stop. "
            "Do not ask a follow-up question. Do not call any tools."
        )
        if request.farewell:
            closing_instruction += f" Use this closing message: {request.farewell}"
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
