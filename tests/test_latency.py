from __future__ import annotations

import pytest

from lobby_wake.latency import build_report, format_report, percentile


def test_build_report_extracts_activation_stages() -> None:
    records = [
        {
            "event": "wake.detected",
            "monotonic_ns": 1_000_000_000,
            "wake_detected_at_ns": 1_000_000_000,
            "detector_call_ms": 2.5,
        },
        {
            "event": "wake.speech_tail_estimated",
            "monotonic_ns": 1_000_500_000,
            "estimated_speech_end_to_wake_ms": 120.0,
        },
        {"event": "activation.listening", "monotonic_ns": 1_001_000_000},
        {"event": "agent.started", "monotonic_ns": 1_002_000_000},
        {"event": "agent.connection_reused", "monotonic_ns": 1_003_000_000},
        {"event": "agent.first_audio_sent", "monotonic_ns": 1_004_000_000},
        {"event": "agent.user_speech_started", "monotonic_ns": 1_010_000_000},
        {"event": "agent.user_speech_stopped", "monotonic_ns": 1_100_000_000},
        {"event": "agent.first_response_received", "monotonic_ns": 1_300_000_000},
        {"event": "agent.first_response_played", "monotonic_ns": 1_305_000_000},
        {
            "event": "agent.playback_interrupted",
            "monotonic_ns": 1_400_000_000,
            "vad_to_playback_stop_ms": 4.5,
        },
    ]

    report = build_report(records)

    assert report["speech_end_to_wake"]["p50"] == 120.0
    assert report["speech_end_to_feedback"]["p50"] == 121.0
    assert report["wake_detector_call"]["p50"] == 2.5
    assert report["wake_to_feedback"]["p50"] == 1.0
    assert report["wake_to_agent_start"]["p50"] == 2.0
    assert report["wake_to_warm_connection"]["p50"] == 3.0
    assert report["wake_to_cold_connection"]["count"] == 0
    assert report["wake_to_first_audio_sent"]["p50"] == 4.0
    assert report["wake_to_server_speech"]["p50"] == 10.0
    assert report["speech_stop_to_response"]["p50"] == 200.0
    assert report["speech_stop_to_playback"]["p50"] == 205.0
    assert report["wake_to_first_playback"]["p50"] == 305.0
    assert report["response_to_playback"]["p50"] == 5.0
    assert report["vad_to_playback_stop"]["p50"] == 4.5


def test_percentile_interpolates() -> None:
    assert percentile([1.0, 2.0, 3.0, 4.0], 0.5) == 2.5
    assert percentile([1.0, 2.0, 3.0, 4.0], 0.95) == pytest.approx(3.85)


def test_format_report_marks_missing_metrics() -> None:
    report = build_report([])

    output = format_report(report)

    assert "Wake → listening feedback" in output
    assert "—" in output
