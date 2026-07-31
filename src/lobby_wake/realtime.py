from __future__ import annotations

import base64
import json
import threading
import time
from collections import deque
from typing import Any

import numpy as np

from .events import EventLogger, WakeEvent
from .playback import AudioPlayer
from .ring_buffer import FloatAudio

REALTIME_SAMPLE_RATE = 24_000
DEFAULT_INSTRUCTIONS = (
    "You are Lobby, a concise and friendly voice assistant. "
    "Respond naturally and briefly unless the user asks for detail. "
    "The user may begin by saying your wake phrase, Hey Lobby."
)


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


def build_session_update(model: str, voice: str, instructions: str) -> dict[str, Any]:
    return {
        "type": "session.update",
        "session": {
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": REALTIME_SAMPLE_RATE},
                    "turn_detection": {
                        "type": "semantic_vad",
                        "eagerness": "high",
                        "create_response": True,
                        "interrupt_response": True,
                    },
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
        full_duplex: bool = False,
        preconnect: bool = True,
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
        self._transcript_parts: list[str] = []

    @property
    def active(self) -> bool:
        return self._active

    def prepare(self) -> None:
        self._player.start()
        self._prepared = True
        self._logger.emit(
            "agent.prepared",
            adapter="openai_realtime",
            model=self._model,
            voice=self._voice,
            full_duplex=self._full_duplex,
            preconnect=self._preconnect,
        )
        if self._preconnect:
            self._logger.emit("agent.preconnection_started", adapter="openai_realtime")
            self._ensure_connection()

    def start(self, initial_audio: FloatAudio, sample_rate: int, wake: WakeEvent) -> None:
        if self._active:
            return
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
            self._transcript_parts.clear()
            self._pending_audio.clear()
            if not connection_ready:
                self._pending_audio.append(initial_pcm16)
        self._logger.emit(
            "agent.started",
            adapter="openai_realtime",
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
        if not self._active or self._last_activity_ns is None:
            return
        if time.monotonic_ns() - self._last_activity_ns >= self._timeout_ns:
            self._logger.emit(
                "agent.inactivity_timeout",
                adapter="openai_realtime",
                timeout_ms=self._timeout_ns / 1_000_000,
            )
            self.stop()

    def stop(self) -> None:
        with self._state_lock:
            was_active = self._active
            started_at_ns = self._started_at_ns
            self._active = False
            self._ready = False
            self._ready_at_ns = None
            self._pending_audio.clear()
            ws, self._ws = self._ws, None
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
        self._send_event(build_session_update(self._model, self._voice, self._instructions), ws)

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
        elif event_type == "input_audio_buffer.speech_started":
            self._last_activity_ns = time.monotonic_ns()
            self._logger.emit("agent.user_speech_started")
        elif event_type == "input_audio_buffer.speech_stopped":
            self._last_activity_ns = time.monotonic_ns()
            self._logger.emit("agent.user_speech_stopped")
        elif event_type == "response.output_audio.delta":
            self._handle_audio_delta(event)
        elif event_type == "response.output_audio_transcript.delta":
            self._transcript_parts.append(event.get("delta", ""))
        elif event_type == "response.output_audio_transcript.done":
            transcript = event.get("transcript") or "".join(self._transcript_parts)
            self._transcript_parts.clear()
            self._logger.emit("agent.response_transcript", transcript=transcript)
        elif event_type == "response.done":
            self._last_activity_ns = time.monotonic_ns()
            status = event.get("response", {}).get("status")
            self._logger.emit("agent.response_done", status=status)
        elif event_type == "error":
            error = event.get("error", {})
            self._logger.emit(
                "agent.api_error",
                error_type=error.get("type"),
                code=error.get("code"),
                detail=error.get("message"),
            )

    def _handle_audio_delta(self, event: dict[str, Any]) -> None:
        try:
            pcm16 = base64.b64decode(event["delta"])
        except (KeyError, ValueError):
            self._logger.emit("agent.protocol_error", detail="invalid output audio delta")
            return
        self._last_activity_ns = time.monotonic_ns()
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
        self._player.enqueue(pcm16, self._mark_first_playback)

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

    def _send_audio(self, pcm16: bytes) -> bool:
        return self._send_event(
            {
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(pcm16).decode("ascii"),
            }
        )

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
