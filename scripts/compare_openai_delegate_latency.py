from __future__ import annotations

import argparse
import os
import statistics
import sys
import threading
import time
import wave
from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np
from dotenv import load_dotenv

from lobby_wake.agent import DelegatePrepareContext, DelegateStartContext
from lobby_wake.conversation import ConversationController
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.process_delegate import ProcessConversationDelegate
from lobby_wake.realtime import OpenAIRealtimeAgent


class ObservingLogger:
    def __init__(self, output: Path) -> None:
        self._logger = EventLogger(output)
        self._condition = threading.Condition()
        self._records: list[dict[str, Any]] = []

    def emit(self, event: str, **fields: Any) -> int:
        emitted_at_ns = self._logger.emit(event, **fields)
        with self._condition:
            self._records.append(
                {"event": event, "monotonic_ns": emitted_at_ns, **fields}
            )
            self._condition.notify_all()
        return emitted_at_ns

    def records_since(self, event: str, start_index: int) -> list[dict[str, Any]]:
        with self._condition:
            return [
                record for record in self._records[start_index:] if record["event"] == event
            ]

    @property
    def count(self) -> int:
        with self._condition:
            return len(self._records)

    def wait_for(
        self,
        event: str,
        start_index: int,
        *,
        timeout_seconds: float,
        poll: Callable[[], None],
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            poll()
            records = self.records_since(event, start_index)
            if records:
                return records[0]
            with self._condition:
                self._condition.wait(timeout=0.01)
        raise TimeoutError(f"timed out waiting for {event}")

    def close(self) -> None:
        self._logger.close()


def load_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise ValueError("sample must be a mono signed-16-bit WAV")
        sample_rate = source.getframerate()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
    return audio.astype(np.float32) / 32768.0, sample_rate


def wait_until(
    condition: Callable[[], bool],
    poll: Callable[[], None],
    *,
    timeout_seconds: float = 15,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        poll()
        if condition():
            return
        time.sleep(0.01)
    raise TimeoutError("condition was not reached before timeout")


def run_activation(
    delegate: Any,
    controller: ConversationController,
    logger: ObservingLogger,
    audio: np.ndarray,
    sample_rate: int,
    *,
    timeout_seconds: float,
) -> dict[str, float]:
    controller.finish()
    controller.begin()
    start_index = logger.count
    wake = WakeEvent("HEY LOBBY", time.monotonic_ns())
    delegate.start(
        DelegateStartContext(
            wake=wake,
            conversation=controller.handle,
            sample_rate=sample_rate,
            initial_audio=audio,
        )
    )
    response = logger.wait_for(
        "agent.first_response_received",
        start_index,
        timeout_seconds=timeout_seconds,
        poll=delegate.poll,
    )
    first_audio = logger.records_since("agent.first_audio_sent", start_index)
    playback = logger.wait_for(
        "agent.first_response_played",
        start_index,
        timeout_seconds=timeout_seconds,
        poll=delegate.poll,
    )
    speech_stopped = logger.records_since("agent.user_speech_stopped", start_index)
    result = {
        "wake_to_response_ms": float(response["wake_to_response_ms"]),
        "wake_to_playback_ms": float(playback["wake_to_playback_ms"]),
    }
    if first_audio:
        result["wake_to_first_audio_sent_ms"] = float(
            first_audio[0]["wake_to_first_audio_sent_ms"]
        )
    if speech_stopped:
        result["speech_stop_to_response_ms"] = (
            response["monotonic_ns"] - speech_stopped[0]["monotonic_ns"]
        ) / 1_000_000
    dispatch = logger.records_since("delegate.activation_started", start_index)
    if dispatch:
        result["delegate_dispatch_ms"] = float(dispatch[0]["activation_dispatch_ms"])
    delegate.stop()
    return result


def summarize(label: str, results: list[dict[str, float]]) -> None:
    print(label)
    for field in (
        "delegate_dispatch_ms",
        "wake_to_first_audio_sent_ms",
        "speech_stop_to_response_ms",
        "wake_to_response_ms",
        "wake_to_playback_ms",
    ):
        values = [result[field] for result in results if field in result]
        if values:
            print(
                f"  {field}: n={len(values)} "
                f"p50={statistics.median(values):.2f} ms "
                f"min={min(values):.2f} ms max={max(values):.2f} ms"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--audio-file",
        type=Path,
        default=Path("recordings/positive/positive-002-quiet.wav"),
    )
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--output-device")
    parser.add_argument("--log-dir", type=Path, default=Path("/tmp"))
    args = parser.parse_args()
    if args.runs <= 0:
        parser.error("runs must be positive")
    load_dotenv()
    audio, sample_rate = load_wav(args.audio_file)
    output_device: int | str | None = args.output_device
    if isinstance(output_device, str) and output_device.isdigit():
        output_device = int(output_device)

    direct_logger = ObservingLogger(args.log_dir / "wake-on-openai-inprocess.jsonl")
    direct_controller = ConversationController(direct_logger)  # type: ignore[arg-type]
    direct = OpenAIRealtimeAgent(
        direct_logger,  # type: ignore[arg-type]
        api_key=os.environ.get("OPENAI_API_KEY", ""),
        output_device=output_device,
        conversation_controller=direct_controller,
    )
    direct.prepare(DelegatePrepareContext(sample_rate=sample_rate))
    wait_until(lambda: direct.status.warm, direct.poll, timeout_seconds=args.timeout)
    direct_results = []
    for run_index in range(args.runs):
        direct_results.append(
            run_activation(
                direct,
                direct_controller,
                direct_logger,
                audio,
                sample_rate,
                timeout_seconds=args.timeout,
            )
        )
        if run_index < args.runs - 1:
            wait_until(
                lambda: not direct.status.warm,
                direct.poll,
                timeout_seconds=args.timeout,
            )
            wait_until(lambda: direct.status.warm, direct.poll, timeout_seconds=args.timeout)
    direct.close()
    direct_logger.close()

    process_logger = ObservingLogger(args.log_dir / "wake-on-openai-process.jsonl")
    process_controller = ConversationController(process_logger)  # type: ignore[arg-type]
    child_command = [
        sys.executable,
        "-m",
        "lobby_wake.openai_process_delegate",
    ]
    if output_device is not None:
        child_command.extend(["--output-device", str(output_device)])
    process = ProcessConversationDelegate(
        process_logger,  # type: ignore[arg-type]
        child_command,
        restart_delay_seconds=0.1,
    )
    process.prepare(DelegatePrepareContext(sample_rate=sample_rate))
    wait_until(lambda: process.status.warm, process.poll, timeout_seconds=args.timeout)
    process_results = []
    for run_index in range(args.runs):
        process_results.append(
            run_activation(
                process,
                process_controller,
                process_logger,
                audio,
                sample_rate,
                timeout_seconds=args.timeout,
            )
        )
        if run_index < args.runs - 1:
            wait_until(
                lambda: not process.status.warm,
                process.poll,
                timeout_seconds=args.timeout,
            )
            wait_until(lambda: process.status.warm, process.poll, timeout_seconds=args.timeout)
    process.close()
    process_logger.close()

    summarize("In-process OpenAI Realtime", direct_results)
    summarize("OpenAI Realtime behind process delegate", process_results)


if __name__ == "__main__":
    main()
