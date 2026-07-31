from __future__ import annotations

import json
import wave
from collections.abc import Callable

import numpy as np

from lobby_wake.sample_recorder import SamplingSession


class FakeRecorder:
    sample_rate = 16_000

    def __init__(self) -> None:
        self.record_count = 0
        self.play_count = 0

    def record(self, duration_seconds: float) -> np.ndarray:
        self.record_count += 1
        return np.full(round(duration_seconds * self.sample_rate), 0.1, dtype=np.float32)

    def play(self, samples: np.ndarray) -> None:
        self.play_count += 1


def scripted_input(answers: list[str]) -> Callable[[str], str]:
    answer_iterator = iter(answers)

    def read(_prompt: str) -> str:
        return next(answer_iterator)

    return read


def test_session_tests_microphone_redoes_and_saves_approved_samples(tmp_path) -> None:
    recorder = FakeRecorder()
    input_fn = scripted_input(
        [
            "",  # begin microphone test
            "y",  # microphone works
            "q",  # positive environment is quiet
            "",  # begin positive attempt 1
            "r",  # reject attempt 1
            "",  # begin positive attempt 2
            "y",  # keep attempt 2
            "n",  # negative environment has noise
            "television",
            "",  # begin negative sample
            "p",  # replay it
            "y",  # keep it
        ]
    )
    output: list[str] = []
    session = SamplingSession(
        recorder,
        tmp_path,
        duration_seconds=0.1,
        test_duration_seconds=0.05,
        input_fn=input_fn,
        output_fn=output.append,
    )

    session.run(positive_count=1, negative_count=1)

    assert recorder.record_count == 4
    assert recorder.play_count == 5
    positive = tmp_path / "positive" / "positive-001-quiet.wav"
    negative = tmp_path / "negative" / "negative-001-noise.wav"
    assert positive.is_file()
    assert negative.is_file()
    with wave.open(str(positive), "rb") as recorded:
        assert recorded.getnchannels() == 1
        assert recorded.getsampwidth() == 2
        assert recorded.getframerate() == 16_000
    manifest = [
        json.loads(line)
        for line in (tmp_path / "manifest.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert [entry["category"] for entry in manifest] == ["positive", "negative"]
    assert manifest[1]["noise_description"] == "television"


def test_session_continues_numbering_existing_samples(tmp_path) -> None:
    existing = tmp_path / "positive" / "positive-004-quiet.wav"
    existing.parent.mkdir(parents=True)
    existing.touch()
    recorder = FakeRecorder()
    input_fn = scripted_input(["", "y", "q", "", "y"])
    session = SamplingSession(
        recorder,
        tmp_path,
        duration_seconds=0.1,
        input_fn=input_fn,
        output_fn=lambda _message: None,
    )

    session.run(positive_count=1, negative_count=0)

    assert (tmp_path / "positive" / "positive-005-quiet.wav").is_file()
