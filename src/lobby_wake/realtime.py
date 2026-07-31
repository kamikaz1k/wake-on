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
        self._player = AudioPlayer(device=output_device)
        self._pending_audio: deque[bytes] = deque(maxlen=500)
        self._send_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._ws = None
        self._thread: threading.Thread | None = None
        self._active = False
        self._ready = False
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
        self._logger.emit(
            "agent.prepared",
            adapter="openai_realtime",
            model=self._model,
            voice=self._voice,
            full_duplex=self._full_duplex,
        )

    def start(self, initial_audio: FloatAudio, sample_rate: int, wake: WakeEvent) -> None:
        if self._active:
            return
        now_ns = time.monotonic_ns()
        with self._state_lock:
            self._active = True
            self._ready = False
            self._started_at_ns = now_ns
            self._last_activity_ns = now_ns
            self._first_response_received = False
            self._first_response_played = False
            self._transcript_parts.clear()
            self._pending_audio.clear()
            self._pending_audio.append(float_audio_to_pcm16(initial_audio, sample_rate))
        self._logger.emit(
            "agent.started",
            adapter="openai_realtime",
            wake_phrase=wake.phrase,
            wake_to_agent_start_ms=(now_ns - wake.detected_at_ns) / 1_000_000,
            initial_audio_ms=initial_audio.size / sample_rate * 1000,
        )
        self._thread = threading.Thread(
            target=self._connect,
            name="lobby-realtime-websocket",
            daemon=True,
        )
        self._thread.start()

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
        self._send_audio(pcm16)

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
        if not self._active and self._ws is None:
            return
        started_at_ns = self._started_at_ns
        self._active = False
        self._ready = False
        ws, self._ws = self._ws, None
        if ws is not None:
            ws.close()
        self._player.clear()
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

    def close(self) -> None:
        self.stop()
        self._player.close()

    def _connect(self) -> None:
        import websocket

        url = f"wss://api.openai.com/v1/realtime?model={self._model}"
        self._ws = websocket.WebSocketApp(
            url,
            header={"Authorization": f"Bearer {self._api_key}"},
            on_open=self._on_open,
            on_message=self._on_message,
            on_error=self._on_error,
            on_close=self._on_close,
        )
        self._ws.run_forever()

    def _on_open(self, ws: Any) -> None:
        self._send_event(build_session_update(self._model, self._voice, self._instructions), ws)

    def _on_message(self, _ws: Any, raw_message: str) -> None:
        try:
            event = json.loads(raw_message)
        except json.JSONDecodeError:
            self._logger.emit("agent.protocol_error", detail="invalid JSON from Realtime API")
            return

        event_type = event.get("type")
        if event_type == "session.updated":
            with self._state_lock:
                self._ready = True
                pending = list(self._pending_audio)
                self._pending_audio.clear()
            now_ns = time.monotonic_ns()
            self._last_activity_ns = now_ns
            self._logger.emit(
                "agent.connection_ready",
                adapter="openai_realtime",
                connection_ms=(
                    (now_ns - self._started_at_ns) / 1_000_000
                    if self._started_at_ns is not None
                    else 0
                ),
                buffered_chunks=len(pending),
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

    def _send_audio(self, pcm16: bytes) -> None:
        self._send_event(
            {
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(pcm16).decode("ascii"),
            }
        )

    def _send_event(self, event: dict[str, Any], ws: Any | None = None) -> None:
        socket = ws or self._ws
        if socket is None:
            return
        with self._send_lock:
            socket.send(json.dumps(event, separators=(",", ":")))

    def _on_error(self, _ws: Any, error: object) -> None:
        self._logger.emit("agent.connection_error", detail=str(error))
        self._active = False

    def _on_close(self, _ws: Any, status_code: int | None, message: str | None) -> None:
        was_active = self._active
        self._ready = False
        self._ws = None
        if was_active:
            self._logger.emit(
                "agent.connection_closed",
                status_code=status_code,
                detail=message,
            )
            self._active = False
