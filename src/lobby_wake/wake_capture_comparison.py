from __future__ import annotations

import argparse
import json
import subprocess
import time
import wave
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Protocol

import numpy as np

from .cli import DEFAULT_KEYWORDS_FILE, DEFAULT_MODEL_DIR
from .events import EventLogger, WakeEvent
from .native_media import DEFAULT_NATIVE_MEDIA_HELPER, NativeMacMedia, NativeWakeAudioSource
from .ring_buffer import FloatAudio, estimate_speech_tail
from .sample_recorder import SoundDeviceRecorder, device_value, write_wav
from .wake import SherpaWakeWordEngine, WakeWordEngine

Input = Callable[[str], str]
Output = Callable[[str], None]


class TrialRecorder(Protocol):
    sample_rate: int

    def start(self) -> None: ...

    def record(self, duration_seconds: float) -> FloatAudio: ...

    def close(self) -> None: ...


class RawTrialRecorder:
    sample_rate = 16_000

    def __init__(self, device: int | str | None = None) -> None:
        self._recorder = SoundDeviceRecorder(sample_rate=self.sample_rate, input_device=device)

    def start(self) -> None:
        pass

    def record(self, duration_seconds: float) -> FloatAudio:
        return self._recorder.record(duration_seconds)

    def close(self) -> None:
        pass


class NativeTrialRecorder:
    sample_rate = 16_000

    def __init__(
        self,
        logger: EventLogger,
        helper: Path = DEFAULT_NATIVE_MEDIA_HELPER,
    ) -> None:
        self._media = NativeMacMedia(logger, (helper,))
        self._source = NativeWakeAudioSource(self._media)
        self._frames = self._source.frames()

    def start(self) -> None:
        self._media.start()

    def record(self, duration_seconds: float) -> FloatAudio:
        target_samples = round(duration_seconds * self.sample_rate)
        self._source.discard_pending()
        chunks: list[FloatAudio] = []
        captured = 0
        while captured < target_samples:
            chunk = next(self._frames)
            chunks.append(chunk)
            captured += chunk.size
        return np.concatenate(chunks)[:target_samples]

    def close(self) -> None:
        self._source.close()
        self._media.close()


@dataclass(frozen=True, slots=True)
class WakeEvaluation:
    detected: bool
    phrase: str | None
    detection_audio_ms: float | None
    estimated_phrase_end_to_detection_ms: float | None
    detector_runtime_ms: float


@dataclass(frozen=True, slots=True)
class KeptTrial:
    mode: str
    attempt: int
    path: str
    duration_seconds: float
    peak: float
    rms: float
    evaluation: WakeEvaluation


def evaluate_wake(
    detector: WakeWordEngine,
    samples: FloatAudio,
    sample_rate: int,
    *,
    block_ms: int = 80,
) -> WakeEvaluation:
    detector.reset()
    block_size = max(1, round(sample_rate * block_ms / 1000))
    runtime_ns = 0
    event: WakeEvent | None = None
    detected_end = 0
    for start in range(0, samples.size, block_size):
        end = min(samples.size, start + block_size)
        call_started = time.monotonic_ns()
        event = detector.process(samples[start:end], sample_rate)
        runtime_ns += time.monotonic_ns() - call_started
        if event is not None:
            detected_end = end
            break
    if event is None:
        return WakeEvaluation(False, None, None, None, runtime_ns / 1_000_000)
    tail = estimate_speech_tail(samples[:detected_end], sample_rate)
    return WakeEvaluation(
        True,
        event.phrase,
        detected_end / sample_rate * 1000,
        tail.trailing_silence_ms if tail is not None else None,
        runtime_ns / 1_000_000,
    )


class WakeCaptureComparison:
    def __init__(
        self,
        detector: WakeWordEngine,
        recorders: dict[str, TrialRecorder],
        output_dir: Path,
        *,
        attempts_per_mode: int = 10,
        duration_seconds: float = 3.0,
        test_duration_seconds: float = 1.5,
        input_fn: Input = input,
        output_fn: Output = print,
    ) -> None:
        if attempts_per_mode <= 0:
            raise ValueError("attempts per mode must be positive")
        self._detector = detector
        self._recorders = recorders
        self._output_dir = output_dir
        self._attempts = attempts_per_mode
        self._duration = duration_seconds
        self._test_duration = test_duration_seconds
        self._input = input_fn
        self._output = output_fn
        self._kept: list[KeptTrial] = []

    def run(self, order: Sequence[str]) -> dict[str, object]:
        if set(order) != set(self._recorders) or len(order) != len(self._recorders):
            raise ValueError("comparison order must contain every recorder exactly once")
        self._output_dir.mkdir(parents=True, exist_ok=True)
        self._output("Wake capture A/B comparison")
        self._output(
            f"Collecting {self._attempts} approved attempts per mode. "
            "Audio stays local and is saved for repeatable evaluation."
        )
        for mode in order:
            self._run_mode(mode, self._recorders[mode])
        summary = self._summary(order)
        (self._output_dir / "summary.json").write_text(
            json.dumps(summary, indent=2) + "\n",
            encoding="utf-8",
        )
        self._print_summary(summary)
        return summary

    def _run_mode(self, mode: str, recorder: TrialRecorder) -> None:
        self._output("")
        self._output(f"Starting {mode.upper()} capture phase.")
        recorder.start()
        try:
            self._run_test(mode, recorder)
            kept = 0
            while kept < self._attempts:
                self._output("")
                self._output(f"{mode.upper()} attempt {kept + 1}/{self._attempts}")
                self._output('Say “Hey Lobby” once, naturally, then remain silent.')
                ready = self._input("Press Enter to record, or q to stop: ").strip().lower()
                if ready == "q":
                    raise KeyboardInterrupt
                samples = recorder.record(self._duration)
                evaluation = evaluate_wake(self._detector, samples, recorder.sample_rate)
                peak, rms = audio_levels(samples)
                status = "DETECTED" if evaluation.detected else "MISSED"
                delay = evaluation.estimated_phrase_end_to_detection_ms
                delay_text = f", estimated tail={delay:.0f} ms" if delay is not None else ""
                self._output(
                    f"Result: {status}{delay_text}; peak={peak:.3f}, RMS={rms:.3f}"
                )
                choice = self._ask_choice(
                    "Was that a valid attempt? [k] keep, [r] redo, [q] stop: ",
                    {"k", "r", "q"},
                )
                if choice == "q":
                    raise KeyboardInterrupt
                if choice == "r":
                    self._output("Discarded; this attempt is not part of the denominator.")
                    continue
                kept += 1
                self._save(mode, kept, samples, recorder.sample_rate, evaluation, peak, rms)
        finally:
            recorder.close()

    def _run_test(self, mode: str, recorder: TrialRecorder) -> None:
        while True:
            self._output(f'{mode.upper()} microphone test: say “testing one two”.')
            ready = self._input("Press Enter to test, or q to stop: ").strip().lower()
            if ready == "q":
                raise KeyboardInterrupt
            samples = recorder.record(self._test_duration)
            peak, rms = audio_levels(samples)
            self._output(f"Test capture: peak={peak:.3f}, RMS={rms:.3f}")
            choice = self._ask_choice(
                "Did you speak clearly during the test? [y] yes, [r] retry, [q] stop: ",
                {"y", "r", "q"},
            )
            if choice == "y":
                return
            if choice == "q":
                raise KeyboardInterrupt

    def _save(
        self,
        mode: str,
        attempt: int,
        samples: FloatAudio,
        sample_rate: int,
        evaluation: WakeEvaluation,
        peak: float,
        rms: float,
    ) -> None:
        path = self._output_dir / mode / f"{mode}-{attempt:03d}.wav"
        write_wav(path, samples, sample_rate)
        trial = KeptTrial(
            mode,
            attempt,
            str(path.relative_to(self._output_dir)),
            samples.size / sample_rate,
            peak,
            rms,
            evaluation,
        )
        self._kept.append(trial)
        with (self._output_dir / "trials.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(asdict(trial), ensure_ascii=False) + "\n")

    def _summary(self, order: Sequence[str]) -> dict[str, object]:
        modes: dict[str, object] = {}
        for mode in order:
            trials = [trial for trial in self._kept if trial.mode == mode]
            detected = [trial for trial in trials if trial.evaluation.detected]
            delays = [
                trial.evaluation.estimated_phrase_end_to_detection_ms
                for trial in detected
                if trial.evaluation.estimated_phrase_end_to_detection_ms is not None
            ]
            modes[mode] = {
                "attempts": len(trials),
                "detected": len(detected),
                "hit_rate": len(detected) / len(trials) if trials else 0,
                "estimated_latency_p50_ms": float(np.percentile(delays, 50)) if delays else None,
                "estimated_latency_p95_ms": float(np.percentile(delays, 95)) if delays else None,
            }
        return {"order": list(order), "attempts_per_mode": self._attempts, "modes": modes}

    def _print_summary(self, summary: dict[str, object]) -> None:
        self._output("")
        self._output("Comparison complete")
        modes = summary["modes"]
        assert isinstance(modes, dict)
        for mode, value in modes.items():
            assert isinstance(value, dict)
            self._output(
                f"{mode}: {value['detected']}/{value['attempts']} detected "
                f"({value['hit_rate']:.0%})"
            )
        self._output(f"Results saved in {self._output_dir}")

    def _ask_choice(self, prompt: str, allowed: set[str]) -> str:
        while True:
            choice = self._input(prompt).strip().lower()
            if choice in allowed:
                return choice
            self._output(f"Please enter one of: {', '.join(sorted(allowed))}")


def audio_levels(samples: FloatAudio) -> tuple[float, float]:
    if not samples.size:
        return 0, 0
    return float(np.max(np.abs(samples))), float(np.sqrt(np.mean(np.square(samples))))


def resample_with_native_helper(
    pcm16: bytes,
    helper: Path,
    source_rate: int,
    destination_rate: int,
) -> bytes:
    result = subprocess.run(
        (str(helper), "--resample-stdin", str(source_rate), str(destination_rate)),
        input=pcm16,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(detail or "native sample-rate conversion failed")
    return result.stdout


def compare_saved_recordings(
    detector: WakeWordEngine,
    recordings_dir: Path,
    helper: Path,
) -> dict[str, object]:
    trials: list[dict[str, object]] = []
    for path in sorted(recordings_dir.glob("*.wav")):
        with wave.open(str(path), "rb") as source:
            if (
                source.getnchannels() != 1
                or source.getsampwidth() != 2
                or source.getframerate() != 16_000
            ):
                raise ValueError(f"{path} must be mono 16-bit PCM at 16 kHz")
            original_pcm = source.readframes(source.getnframes())
        upsampled = resample_with_native_helper(original_pcm, helper, 16_000, 48_000)
        roundtrip_pcm = resample_with_native_helper(upsampled, helper, 48_000, 16_000)
        original = np.frombuffer(original_pcm, dtype="<i2").astype(np.float32) / 32768
        roundtrip = np.frombuffer(roundtrip_pcm, dtype="<i2").astype(np.float32) / 32768
        output_samples = roundtrip.size
        if roundtrip.size < original.size:
            roundtrip = np.pad(roundtrip, (0, original.size - roundtrip.size))
        else:
            roundtrip = roundtrip[: original.size]
        baseline = evaluate_wake(detector, original, 16_000)
        converted = evaluate_wake(detector, roundtrip, 16_000)
        trials.append(
            {
                "path": path.name,
                "input_samples": original.size,
                "roundtrip_samples": output_samples,
                "baseline": asdict(baseline),
                "converted": asdict(converted),
            }
        )
    baseline_detected = sum(bool(trial["baseline"]["detected"]) for trial in trials)  # type: ignore[index]
    converted_detected = sum(bool(trial["converted"]["detected"]) for trial in trials)  # type: ignore[index]
    changed = [
        trial["path"]
        for trial in trials
        if trial["baseline"]["detected"] != trial["converted"]["detected"]  # type: ignore[index]
    ]
    return {
        "recordings": len(trials),
        "baseline_detected": baseline_detected,
        "converted_detected": converted_detected,
        "changed_detection": changed,
        "trials": trials,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-compare-wake-capture")
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--duration", type=float, default=3.0)
    parser.add_argument("--test-duration", type=float, default=1.5)
    parser.add_argument("--order", choices=("raw-first", "native-first"), default="raw-first")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--input-device")
    parser.add_argument("--native-media-helper", type=Path, default=DEFAULT_NATIVE_MEDIA_HELPER)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--keywords-file", type=Path, default=DEFAULT_KEYWORDS_FILE)
    parser.add_argument(
        "--reuse-recordings",
        type=Path,
        help="Run a 16→48→16 kHz converter preservation check on existing WAVs",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.attempts <= 0 or args.duration <= 0 or args.test_duration <= 0:
        raise SystemExit("attempts and durations must be positive")
    run_name = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    output_dir = args.output_dir or Path("recordings/wake-comparison") / run_name
    detector = SherpaWakeWordEngine(args.model_dir, args.keywords_file)
    if args.reuse_recordings is not None:
        output_dir.mkdir(parents=True, exist_ok=True)
        summary = compare_saved_recordings(
            detector,
            args.reuse_recordings,
            args.native_media_helper,
        )
        (output_dir / "converter-summary.json").write_text(
            json.dumps(summary, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"Converter preservation: {summary['converted_detected']}/"
            f"{summary['recordings']} after conversion versus "
            f"{summary['baseline_detected']}/{summary['recordings']} baseline"
        )
        print(f"Changed detections: {summary['changed_detection'] or 'none'}")
        print(f"Results saved in {output_dir}")
        return
    logger = EventLogger(output_dir / "native-media.jsonl")
    recorders: dict[str, TrialRecorder] = {
        "raw": RawTrialRecorder(device_value(args.input_device)),
        "native": NativeTrialRecorder(logger, args.native_media_helper),
    }
    order = ("raw", "native") if args.order == "raw-first" else ("native", "raw")
    comparison = WakeCaptureComparison(
        detector,
        recorders,
        output_dir,
        attempts_per_mode=args.attempts,
        duration_seconds=args.duration,
        test_duration_seconds=args.test_duration,
    )
    try:
        comparison.run(order)
    except KeyboardInterrupt:
        print("\nStopped. Previously approved trials remain saved.")
    finally:
        logger.close()


if __name__ == "__main__":
    main()
