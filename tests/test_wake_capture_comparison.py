from __future__ import annotations

import json
import time
from collections.abc import Callable

import numpy as np

from lobby_wake.events import WakeEvent
from lobby_wake.sample_recorder import write_wav
from lobby_wake.wake_capture_comparison import (
    WakeCaptureComparison,
    compare_saved_recordings,
    evaluate_wake,
)


class ThresholdDetector:
    def process(self, samples: np.ndarray, sample_rate: int) -> WakeEvent | None:
        del sample_rate
        if np.max(samples, initial=0) > 0.05:
            return WakeEvent("HEY LOBBY", time.monotonic_ns())
        return None

    def reset(self) -> None:
        pass


class FakeRecorder:
    sample_rate = 16_000

    def __init__(self, level: float) -> None:
        self.level = level
        self.started = False
        self.closed = False

    def start(self) -> None:
        self.started = True

    def record(self, duration_seconds: float) -> np.ndarray:
        return np.full(round(duration_seconds * self.sample_rate), self.level, dtype=np.float32)

    def close(self) -> None:
        self.closed = True


def scripted_input(answers: list[str]) -> Callable[[str], str]:
    iterator = iter(answers)
    return lambda _prompt: next(iterator)


def test_evaluate_wake_reports_detection_and_miss() -> None:
    detector = ThresholdDetector()

    detected = evaluate_wake(detector, np.ones(1_600, dtype=np.float32), 16_000)
    missed = evaluate_wake(detector, np.zeros(1_600, dtype=np.float32), 16_000)

    assert detected.detected is True
    assert detected.phrase == "HEY LOBBY"
    assert detected.detection_audio_ms == 80
    assert missed.detected is False


def test_comparison_records_kept_attempts_and_summary(tmp_path) -> None:
    raw = FakeRecorder(0.1)
    native = FakeRecorder(0.0)
    comparison = WakeCaptureComparison(
        ThresholdDetector(),
        {"raw": raw, "native": native},
        tmp_path,
        attempts_per_mode=1,
        duration_seconds=0.1,
        test_duration_seconds=0.05,
        input_fn=scripted_input(
            [
                "", "y", "", "k",  # raw test and attempt
                "", "y", "", "k",  # native test and attempt
            ]
        ),
        output_fn=lambda _message: None,
    )

    summary = comparison.run(("raw", "native"))

    assert raw.started and raw.closed
    assert native.started and native.closed
    assert summary["modes"]["raw"]["detected"] == 1
    assert summary["modes"]["native"]["detected"] == 0
    assert (tmp_path / "raw" / "raw-001.wav").is_file()
    assert (tmp_path / "native" / "native-001.wav").is_file()
    trials = [
        json.loads(line)
        for line in (tmp_path / "trials.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [trial["evaluation"]["detected"] for trial in trials] == [True, False]


def test_saved_recording_comparison_reuses_identical_audio(tmp_path, monkeypatch) -> None:
    samples = np.full(1_600, 0.1, dtype=np.float32)
    write_wav(tmp_path / "positive.wav", samples, 16_000)
    monkeypatch.setattr(
        "lobby_wake.wake_capture_comparison.resample_with_native_helper",
        lambda pcm, _helper, _source_rate, _destination_rate: pcm,
    )

    summary = compare_saved_recordings(
        ThresholdDetector(),
        tmp_path,
        tmp_path / "unused-helper",
    )

    assert summary["baseline_detected"] == 1
    assert summary["converted_detected"] == 1
    assert summary["changed_detection"] == []
