from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True, slots=True)
class Metric:
    key: str
    label: str


METRICS = (
    Metric("speech_end_to_wake", "Estimated speech end → wake"),
    Metric("speech_end_to_feedback", "Estimated speech end → feedback"),
    Metric("wake_detector_call", "Wake detector call"),
    Metric("wake_to_feedback", "Wake → listening feedback"),
    Metric("wake_to_agent_start", "Wake → agent start"),
    Metric("wake_to_warm_connection", "Wake → warm connection"),
    Metric("wake_to_cold_connection", "Wake → cold connection"),
    Metric("wake_to_first_audio_sent", "Wake → first audio sent"),
    Metric("wake_to_server_speech", "Wake → server speech detected"),
    Metric("speech_stop_to_response", "Speech stop → response received"),
    Metric("speech_stop_to_playback", "Speech stop → first playback"),
    Metric("wake_to_first_playback", "Wake → first playback"),
    Metric("response_to_playback", "Response received → playback"),
    Metric("vad_to_playback_stop", "VAD speech start → playback stopped"),
)


def load_records(paths: Iterable[Path]) -> list[dict[str, Any]]:
    records = []
    for path in paths:
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: invalid JSON") from error
                record["_source"] = str(path)
                records.append(record)
    records.sort(key=lambda record: (record["_source"], record.get("monotonic_ns", 0)))
    return records


def extract_metrics(records: Iterable[dict[str, Any]]) -> dict[str, list[float]]:
    values: dict[str, list[float]] = defaultdict(list)
    wake_ns: int | None = None
    speech_stopped_ns: int | None = None
    response_received_ns: int | None = None
    source: str | None = None
    server_speech_recorded = False
    speech_end_to_wake_ms: float | None = None
    wake_to_feedback_ms: float | None = None

    for record in records:
        record_source = record.get("_source")
        if isinstance(record_source, str) and record_source != source:
            source = record_source
            wake_ns = None
            speech_stopped_ns = None
            response_received_ns = None
            server_speech_recorded = False
            speech_end_to_wake_ms = None
            wake_to_feedback_ms = None
        event = record.get("event")
        now_ns = record.get("monotonic_ns")
        if not isinstance(now_ns, int):
            continue

        if event == "wake.detected":
            explicit_wake_ns = record.get("wake_detected_at_ns")
            wake_ns = explicit_wake_ns if isinstance(explicit_wake_ns, int) else now_ns
            speech_stopped_ns = None
            response_received_ns = None
            server_speech_recorded = False
            speech_end_to_wake_ms = None
            wake_to_feedback_ms = None
            detector_call_ms = record.get("detector_call_ms")
            if isinstance(detector_call_ms, int | float):
                values["wake_detector_call"].append(float(detector_call_ms))
            continue

        if event == "wake.speech_tail_estimated":
            estimate = record.get("estimated_speech_end_to_wake_ms")
            if isinstance(estimate, int | float):
                speech_end_to_wake_ms = float(estimate)
                values["speech_end_to_wake"].append(speech_end_to_wake_ms)
                if wake_to_feedback_ms is not None:
                    values["speech_end_to_feedback"].append(
                        speech_end_to_wake_ms + wake_to_feedback_ms
                    )
            continue

        if wake_ns is None:
            continue

        if event == "activation.listening":
            explicit_feedback_ms = record.get("wake_to_feedback_ms")
            wake_to_feedback_ms = (
                float(explicit_feedback_ms)
                if isinstance(explicit_feedback_ms, int | float)
                else _milliseconds(wake_ns, now_ns)
            )
            values["wake_to_feedback"].append(wake_to_feedback_ms)
            if speech_end_to_wake_ms is not None:
                values["speech_end_to_feedback"].append(
                    speech_end_to_wake_ms + wake_to_feedback_ms
                )
        elif event == "agent.started":
            values["wake_to_agent_start"].append(
                _field_or_delta(record, "wake_to_agent_start_ms", wake_ns, now_ns)
            )
        elif event == "agent.connection_reused":
            values["wake_to_warm_connection"].append(
                _field_or_delta(record, "wake_to_connection_ready_ms", wake_ns, now_ns)
            )
        elif event == "agent.connection_ready":
            values["wake_to_cold_connection"].append(
                _field_or_delta(record, "wake_to_connection_ready_ms", wake_ns, now_ns)
            )
        elif event == "agent.first_audio_sent":
            values["wake_to_first_audio_sent"].append(
                _field_or_delta(record, "wake_to_first_audio_sent_ms", wake_ns, now_ns)
            )
        elif event == "agent.user_speech_started" and not server_speech_recorded:
            values["wake_to_server_speech"].append(_milliseconds(wake_ns, now_ns))
            server_speech_recorded = True
        elif event == "agent.user_speech_stopped":
            speech_stopped_ns = now_ns
        elif event == "agent.first_response_received":
            response_received_ns = now_ns
            if speech_stopped_ns is not None:
                values["speech_stop_to_response"].append(
                    _milliseconds(speech_stopped_ns, now_ns)
                )
        elif event == "agent.first_response_played":
            values["wake_to_first_playback"].append(
                _field_or_delta(record, "wake_to_playback_ms", wake_ns, now_ns)
            )
            if speech_stopped_ns is not None:
                values["speech_stop_to_playback"].append(
                    _milliseconds(speech_stopped_ns, now_ns)
                )
            if response_received_ns is not None:
                values["response_to_playback"].append(
                    _milliseconds(response_received_ns, now_ns)
                )
        elif event == "agent.playback_interrupted":
            interruption_ms = record.get("vad_to_playback_stop_ms")
            if isinstance(interruption_ms, int | float):
                values["vad_to_playback_stop"].append(float(interruption_ms))

    return values


def summarize(values: Iterable[float]) -> dict[str, float | int]:
    ordered = sorted(values)
    if not ordered:
        return {"count": 0}
    return {
        "count": len(ordered),
        "min": ordered[0],
        "p50": percentile(ordered, 0.50),
        "p95": percentile(ordered, 0.95),
        "max": ordered[-1],
    }


def percentile(ordered: list[float], quantile: float) -> float:
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def build_report(records: Iterable[dict[str, Any]]) -> dict[str, dict[str, float | int]]:
    values = extract_metrics(records)
    return {metric.key: summarize(values[metric.key]) for metric in METRICS}


def format_report(report: dict[str, dict[str, float | int]]) -> str:
    header = f"{'Metric':<36} {'n':>4} {'min':>9} {'p50':>9} {'p95':>9} {'max':>9}"
    rows = [header, "-" * len(header)]
    for metric in METRICS:
        summary = report[metric.key]
        count = int(summary["count"])
        if count == 0:
            rows.append(f"{metric.label:<36} {count:>4} {'—':>9} {'—':>9} {'—':>9} {'—':>9}")
            continue
        rows.append(
            f"{metric.label:<36} {count:>4} "
            f"{summary['min']:>8.2f}ms "
            f"{summary['p50']:>8.2f}ms "
            f"{summary['p95']:>8.2f}ms "
            f"{summary['max']:>8.2f}ms"
        )
    return "\n".join(rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-latency-report")
    parser.add_argument(
        "logs",
        nargs="*",
        type=Path,
        default=[Path("latency.jsonl")],
        help="One or more Lobby Wake JSONL logs",
    )
    parser.add_argument("--json", action="store_true", help="Print the summary as JSON")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    report = build_report(load_records(args.logs))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(format_report(report))


def _milliseconds(start_ns: int, end_ns: int) -> float:
    return (end_ns - start_ns) / 1_000_000


def _field_or_delta(
    record: dict[str, Any],
    field: str,
    start_ns: int,
    end_ns: int,
) -> float:
    value = record.get(field)
    if isinstance(value, int | float):
        return float(value)
    return _milliseconds(start_ns, end_ns)


if __name__ == "__main__":
    main()
