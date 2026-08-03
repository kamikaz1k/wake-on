from __future__ import annotations

import json
import logging
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, TextIO


@dataclass(frozen=True, slots=True)
class WakeEvent:
    phrase: str
    detected_at_ns: int
    trigger_id: str | None = None

    def __post_init__(self) -> None:
        trigger_id = normalize_trigger_id(self.trigger_id or self.phrase)
        if not trigger_id:
            raise ValueError("wake trigger_id cannot be empty")
        object.__setattr__(self, "trigger_id", trigger_id)


def normalize_trigger_id(value: str) -> str:
    """Convert a spoken or decoder label into a stable routing key."""

    return re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")


class HumanEventFormatter(logging.Formatter):
    """Formats structured events as compact, readable terminal lines."""

    def format(self, record: logging.LogRecord) -> str:
        event_record: dict[str, Any] = record.event_record  # type: ignore[attr-defined]
        timestamp = time.strftime("%H:%M:%S", time.localtime(event_record["wall_time"]))
        event = event_record["event"].replace(".", " ").replace("_", " ").capitalize()
        fields = [
            self._format_field(key, value)
            for key, value in event_record.items()
            if key not in {"event", "monotonic_ns", "wall_time"} and value is not None
        ]
        suffix = f" · {' · '.join(fields)}" if fields else ""
        return f"{timestamp} {record.levelname:<5} {event}{suffix}"

    @staticmethod
    def _format_field(key: str, value: Any) -> str:
        label = key.replace("_", " ")
        if key.endswith("_ms") and isinstance(value, int | float):
            label = label.removesuffix(" ms")
            return f"{label}={value:.2f} ms"
        if isinstance(value, float):
            rendered = f"{value:.3f}"
        elif isinstance(value, bool):
            rendered = str(value).lower()
        elif isinstance(value, str):
            rendered = json.dumps(value, ensure_ascii=False)
        else:
            rendered = str(value)
        return f"{label}={rendered}"


class JsonEventFormatter(logging.Formatter):
    """Preserves the full event record for metrics and later analysis."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps(
            record.event_record,  # type: ignore[attr-defined]
            separators=(",", ":"),
            default=EventLogger.json_default,
        )


class EventLogger:
    """Logs readable terminal events and structured JSONL metrics."""

    def __init__(self, output: Path | None = None, *, stream: TextIO | None = None) -> None:
        self._logger = logging.Logger(f"lobby_wake.events.{id(self)}", level=logging.INFO)
        self._logger.propagate = False
        self._handlers: list[logging.Handler] = []

        console = logging.StreamHandler(stream or sys.stderr)
        console.setFormatter(HumanEventFormatter())
        self._add_handler(console)

        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True)
            structured = logging.FileHandler(output, encoding="utf-8")
            structured.setFormatter(JsonEventFormatter())
            self._add_handler(structured)

    def emit(self, event: str, **fields: Any) -> int:
        now_ns = time.monotonic_ns()
        event_record = {
            "event": event,
            "monotonic_ns": now_ns,
            "wall_time": time.time(),
            **fields,
        }
        self._logger.log(
            self._level_for_event(event),
            event,
            extra={"event_record": event_record},
        )
        return now_ns

    @staticmethod
    def json_default(value: object) -> object:
        if hasattr(value, "__dataclass_fields__"):
            return asdict(value)  # type: ignore[arg-type]
        if isinstance(value, Path):
            return str(value)
        raise TypeError(f"Cannot serialize {type(value).__name__}")

    def close(self) -> None:
        for handler in self._handlers:
            handler.close()
            self._logger.removeHandler(handler)
        self._handlers.clear()

    def _add_handler(self, handler: logging.Handler) -> None:
        self._logger.addHandler(handler)
        self._handlers.append(handler)

    @staticmethod
    def _level_for_event(event: str) -> int:
        if "error" in event:
            return logging.ERROR
        if "timeout" in event or "closed" in event:
            return logging.WARNING
        return logging.INFO
