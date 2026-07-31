from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True, slots=True)
class WakeEvent:
    phrase: str
    detected_at_ns: int


class EventLogger:
    """Writes machine-readable timing events while keeping console output useful."""

    def __init__(self, output: Path | None = None) -> None:
        self._output = output

    def emit(self, event: str, **fields: Any) -> int:
        now_ns = time.monotonic_ns()
        record = {
            "event": event,
            "monotonic_ns": now_ns,
            "wall_time": time.time(),
            **fields,
        }
        line = json.dumps(record, separators=(",", ":"), default=self._json_default)
        print(line, flush=True)
        if self._output is not None:
            self._output.parent.mkdir(parents=True, exist_ok=True)
            with self._output.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        return now_ns

    @staticmethod
    def _json_default(value: object) -> object:
        if hasattr(value, "__dataclass_fields__"):
            return asdict(value)  # type: ignore[arg-type]
        if isinstance(value, Path):
            return str(value)
        raise TypeError(f"Cannot serialize {type(value).__name__}")

