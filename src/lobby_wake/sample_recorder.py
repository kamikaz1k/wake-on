from __future__ import annotations

import argparse
import json
import math
import time
import wave
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import numpy as np

from .ring_buffer import FloatAudio

Input = Callable[[str], str]
Output = Callable[[str], None]

POSITIVE_PROMPTS = (
    'Say “Hey Lobby”, then stop.',
    'Say “Hey Lobby” followed by a natural request.',
    'Say “Hey Lobby” a little faster than usual.',
    'Say “Hey Lobby” a little more quietly than usual.',
    'Say “Hey Lobby” naturally from a different angle or distance.',
)

NEGATIVE_PROMPTS = (
    'Say “Hey” without saying “Lobby”.',
    'Say “Lobby” without saying “Hey”.',
    'Say a normal sentence containing the word “lobby”.',
    'Say a phrase that sounds somewhat similar to “Hey Lobby”.',
    'Speak naturally without saying the wake phrase.',
)


class Recorder(Protocol):
    sample_rate: int

    def record(self, duration_seconds: float) -> FloatAudio: ...

    def play(self, samples: FloatAudio) -> None: ...


class SoundDeviceRecorder:
    def __init__(
        self,
        *,
        sample_rate: int = 16_000,
        input_device: int | str | None = None,
        output_device: int | str | None = None,
    ) -> None:
        self.sample_rate = sample_rate
        self._input_device = input_device
        self._output_device = output_device

    def record(self, duration_seconds: float) -> FloatAudio:
        import sounddevice as sd

        frames = math.ceil(duration_seconds * self.sample_rate)
        captured = sd.rec(
            frames,
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            device=self._input_device,
        )
        sd.wait()
        return np.asarray(captured[:, 0], dtype=np.float32).copy()

    def play(self, samples: FloatAudio) -> None:
        import sounddevice as sd

        sd.play(samples, samplerate=self.sample_rate, device=self._output_device)
        sd.wait()


@dataclass(frozen=True, slots=True)
class Environment:
    name: str
    noise_description: str | None


class SamplingSession:
    def __init__(
        self,
        recorder: Recorder,
        output_dir: Path,
        *,
        duration_seconds: float = 3.0,
        test_duration_seconds: float = 2.0,
        input_fn: Input = input,
        output_fn: Output = print,
    ) -> None:
        self._recorder = recorder
        self._output_dir = output_dir
        self._duration_seconds = duration_seconds
        self._test_duration_seconds = test_duration_seconds
        self._input = input_fn
        self._output = output_fn

    def run(self, positive_count: int, negative_count: int) -> None:
        self._output("Lobby Wake sample recorder")
        self._output("Audio is saved only after you approve each take.")
        self._run_microphone_test()
        self._collect("positive", positive_count, POSITIVE_PROMPTS)
        self._collect("negative", negative_count, NEGATIVE_PROMPTS)
        self._output(f"Done. Samples and manifest are in {self._output_dir}")

    def _run_microphone_test(self) -> None:
        while True:
            self._output("")
            self._output("Microphone test: say “testing one two” after recording starts.")
            ready = self._input("Press Enter to record the test, or q to quit: ").strip().lower()
            if ready == "q":
                raise KeyboardInterrupt
            samples = self._record(self._test_duration_seconds)
            self._output("Playing the test recording...")
            self._recorder.play(samples)
            choice = self._ask_choice(
                "Could you hear yourself clearly? [y] yes, [r] retry, [q] quit: ",
                {"y", "r", "q"},
            )
            if choice == "y":
                return
            if choice == "q":
                raise KeyboardInterrupt

    def _collect(
        self,
        category: str,
        count: int,
        prompts: Sequence[str],
    ) -> None:
        if count == 0:
            return
        directory = self._output_dir / category
        directory.mkdir(parents=True, exist_ok=True)
        next_index = self._next_index(directory, category)

        for offset in range(count):
            index = next_index + offset
            prompt = prompts[offset % len(prompts)]
            self._output("")
            self._output(f"{category.title()} sample {offset + 1}/{count}")
            self._output(prompt)
            environment = self._choose_environment(offset)

            while True:
                ready = self._input("Press Enter when ready, or q to quit: ").strip().lower()
                if ready == "q":
                    raise KeyboardInterrupt
                samples = self._record(self._duration_seconds)
                self._output("Playing this take...")
                self._recorder.play(samples)
                choice = self._ask_choice(
                    "Is this take good? [y] keep, [r] redo, [p] replay, [q] quit: ",
                    {"y", "r", "p", "q"},
                )
                while choice == "p":
                    self._recorder.play(samples)
                    choice = self._ask_choice(
                        "Is this take good? [y] keep, [r] redo, [p] replay, [q] quit: ",
                        {"y", "r", "p", "q"},
                    )
                if choice == "q":
                    raise KeyboardInterrupt
                if choice == "r":
                    self._output("Discarded. Let’s record that sample again.")
                    continue
                self._save_take(
                    samples,
                    category=category,
                    index=index,
                    prompt=prompt,
                    environment=environment,
                )
                break

    def _choose_environment(self, offset: int) -> Environment:
        suggestion = "noise" if (offset + 1) % 3 == 0 else "quiet"
        choice = self._ask_choice(
            f"Environment? [q] quiet, [n] background noise "
            f"(suggested: {suggestion}): ",
            {"q", "n"},
        )
        if choice == "q":
            return Environment("quiet", None)
        description = self._input(
            "Briefly describe the noise (music, television, café, etc.): "
        ).strip()
        return Environment("noise", description or "unspecified")

    def _record(self, duration_seconds: float) -> FloatAudio:
        self._output(f"Recording for {duration_seconds:g} seconds — speak now.")
        samples = self._recorder.record(duration_seconds)
        peak = float(np.max(np.abs(samples))) if samples.size else 0.0
        rms = float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0
        self._output(f"Captured audio: peak={peak:.3f}, RMS={rms:.3f}")
        if peak >= 0.99:
            self._output("Warning: the recording may be clipping.")
        elif peak < 0.02:
            self._output("Warning: the recording is very quiet; check the microphone.")
        return samples

    def _save_take(
        self,
        samples: FloatAudio,
        *,
        category: str,
        index: int,
        prompt: str,
        environment: Environment,
    ) -> Path:
        filename = f"{category}-{index:03d}-{environment.name}.wav"
        path = self._output_dir / category / filename
        write_wav(path, samples, self._recorder.sample_rate)
        peak = float(np.max(np.abs(samples))) if samples.size else 0.0
        rms = float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0
        manifest = {
            "path": str(path.relative_to(self._output_dir)),
            "category": category,
            "index": index,
            "environment": environment.name,
            "noise_description": environment.noise_description,
            "prompt": prompt,
            "sample_rate": self._recorder.sample_rate,
            "duration_seconds": samples.size / self._recorder.sample_rate,
            "peak": peak,
            "rms": rms,
            "recorded_at": time.time(),
        }
        self._output_dir.mkdir(parents=True, exist_ok=True)
        with (self._output_dir / "manifest.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(manifest, ensure_ascii=False) + "\n")
        self._output(f"Saved {path}")
        return path

    def _ask_choice(self, prompt: str, allowed: set[str]) -> str:
        while True:
            choice = self._input(prompt).strip().lower()
            if choice in allowed:
                return choice
            self._output(f"Please enter one of: {', '.join(sorted(allowed))}")

    @staticmethod
    def _next_index(directory: Path, category: str) -> int:
        indices = []
        for path in directory.glob(f"{category}-*.wav"):
            parts = path.stem.split("-", maxsplit=2)
            if len(parts) >= 2 and parts[1].isdigit():
                indices.append(int(parts[1]))
        return max(indices, default=0) + 1


def write_wav(path: Path, samples: FloatAudio, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm16 = (np.clip(samples, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm16.tobytes())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-record-samples")
    parser.add_argument("--output-dir", type=Path, default=Path("recordings"))
    parser.add_argument("--positive", type=nonnegative_int, help="Number of positive samples")
    parser.add_argument("--negative", type=nonnegative_int, help="Number of negative samples")
    parser.add_argument("--duration", type=positive_float, default=3.0)
    parser.add_argument("--test-duration", type=positive_float, default=2.0)
    parser.add_argument("--sample-rate", type=int, default=16_000)
    parser.add_argument("--input-device")
    parser.add_argument("--output-device")
    return parser


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def prompt_count(label: str, input_fn: Input = input) -> int:
    while True:
        try:
            return nonnegative_int(input_fn(f"How many {label} samples? ").strip())
        except (ValueError, argparse.ArgumentTypeError):
            print("Enter a whole number that is zero or greater.")


def device_value(value: str | None) -> int | str | None:
    if value is not None and value.isdigit():
        return int(value)
    return value


def main() -> None:
    args = build_parser().parse_args()
    positive_count = args.positive
    if positive_count is None:
        positive_count = prompt_count("positive")
    negative_count = args.negative
    if negative_count is None:
        negative_count = prompt_count("negative")

    recorder = SoundDeviceRecorder(
        sample_rate=args.sample_rate,
        input_device=device_value(args.input_device),
        output_device=device_value(args.output_device),
    )
    session = SamplingSession(
        recorder,
        args.output_dir,
        duration_seconds=args.duration,
        test_duration_seconds=args.test_duration,
    )
    try:
        session.run(positive_count, negative_count)
    except KeyboardInterrupt:
        print("\nStopped. Previously approved samples are still saved.")


if __name__ == "__main__":
    main()
