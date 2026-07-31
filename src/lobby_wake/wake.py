from __future__ import annotations

import time
from pathlib import Path
from typing import Protocol

from .events import WakeEvent
from .ring_buffer import FloatAudio


class WakeWordEngine(Protocol):
    def process(self, samples: FloatAudio, sample_rate: int) -> WakeEvent | None: ...

    def reset(self) -> None: ...


class SherpaWakeWordEngine:
    """Small adapter around sherpa-onnx's streaming keyword spotter."""

    def __init__(
        self,
        model_dir: Path,
        keywords_file: Path,
        *,
        num_threads: int = 1,
        keywords_score: float = 1.5,
        keywords_threshold: float = 0.25,
        num_trailing_blanks: int = 1,
        model_variant: str = "int8",
    ) -> None:
        import sherpa_onnx

        if model_variant not in {"int8", "fp32"}:
            raise ValueError("model_variant must be 'int8' or 'fp32'")
        encoder = self._find_component(model_dir, "encoder", model_variant)
        decoder = self._find_component(model_dir, "decoder", model_variant)
        joiner = self._find_component(model_dir, "joiner", model_variant)
        tokens = model_dir / "tokens.txt"
        for required in (tokens, keywords_file):
            if not required.is_file():
                raise FileNotFoundError(required)

        self._spotter = sherpa_onnx.KeywordSpotter(
            tokens=str(tokens),
            encoder=str(encoder),
            decoder=str(decoder),
            joiner=str(joiner),
            num_threads=num_threads,
            keywords_file=str(keywords_file),
            keywords_score=keywords_score,
            keywords_threshold=keywords_threshold,
            num_trailing_blanks=num_trailing_blanks,
            provider="cpu",
        )
        self._stream = self._spotter.create_stream()

    def process(self, samples: FloatAudio, sample_rate: int) -> WakeEvent | None:
        self._stream.accept_waveform(sample_rate, samples)
        while self._spotter.is_ready(self._stream):
            self._spotter.decode_stream(self._stream)
        result = self._spotter.get_result(self._stream)
        if not result:
            return None
        event = WakeEvent(phrase=result, detected_at_ns=time.monotonic_ns())
        self._spotter.reset_stream(self._stream)
        return event

    def reset(self) -> None:
        self._spotter.reset_stream(self._stream)

    @staticmethod
    def _find_component(directory: Path, component: str, variant: str) -> Path:
        matches = sorted(directory.glob(f"{component}-*.onnx"))
        if variant == "int8":
            matches = [path for path in matches if path.name.endswith(".int8.onnx")]
        else:
            matches = [path for path in matches if not path.name.endswith(".int8.onnx")]
        if not matches:
            raise FileNotFoundError(f"No {variant} {component} model in {directory}")
        return matches[0]
