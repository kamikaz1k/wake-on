from __future__ import annotations

import base64
import json
import sys
import time
from collections.abc import Callable
from pathlib import Path

import numpy as np

from lobby_wake.agent import (
    DelegateHealth,
    DelegatePrepareContext,
    DelegateStartContext,
)
from lobby_wake.conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from lobby_wake.events import EventLogger, WakeEvent
from lobby_wake.process_delegate import ProcessConversationDelegate, encode_float_audio

FIXTURE = Path(__file__).parent / "fixtures" / "process_delegate.py"


def wait_until(
    condition: Callable[[], bool],
    delegate: ProcessConversationDelegate,
    *,
    timeout_seconds: float = 2.0,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        delegate.poll()
        if condition():
            return
        time.sleep(0.01)
    raise AssertionError("condition was not reached before timeout")


def start_context(
    controller: ConversationController,
    *,
    samples: int = 160,
) -> DelegateStartContext:
    controller.begin()
    return DelegateStartContext(
        wake=WakeEvent("HEY LOBBY", time.monotonic_ns()),
        conversation=controller.handle,
        sample_rate=16_000,
        initial_audio=np.ones(samples, dtype=np.float32),
    )


def test_float_audio_wire_encoding_is_little_endian() -> None:
    encoded = encode_float_audio(np.array([-1.0, 0.5], dtype=np.float32))

    assert encoded["encoding"] == "float32le"
    assert encoded["samples"] == 2
    decoded = np.frombuffer(base64.b64decode(encoded["data"]), dtype="<f4")
    np.testing.assert_array_equal(decoded, [-1.0, 0.5])


def test_process_delegate_prepares_warm_and_completes_graceful_end(tmp_path) -> None:
    log_path = tmp_path / "events.jsonl"
    logger = EventLogger(log_path)
    controller = ConversationController(logger)
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE)],
        restart_delay_seconds=0.01,
    )

    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)

    assert delegate.status.health is DelegateHealth.READY
    assert delegate.status.accepting_activation
    delegate.start(start_context(controller, samples=320))
    delegate.send_audio(np.ones(80, dtype=np.float32), 16_000)
    delegate.request_end(
        EndConversationRequest(
            source=EndSource.USER,
            reason="done",
            mode=EndMode.GRACEFUL,
            requested_at_ns=time.monotonic_ns(),
        )
    )
    wait_until(lambda: not delegate.active, delegate)
    delegate.close()
    logger.close()

    records = [json.loads(line) for line in log_path.read_text().splitlines()]
    process_logs = [record for record in records if record["event"] == "delegate.process_log"]
    assert any(
        record.get("fields", {}).get("initial_audio_samples") == 320
        for record in process_logs
    )
    assert any(
        record.get("fields", {}).get("audio_samples") == 80 for record in process_logs
    )
    assert any(
        record["event"] == "agent.fixture_started"
        and record["delegate_transport"] == "process"
        for record in records
    )
    assert any(record["event"] == "delegate.activation_ended" for record in records)


def test_child_end_request_uses_current_conversation_handle() -> None:
    logger = EventLogger()
    controller = ConversationController(logger)
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE), "--request-end"],
        restart_delay_seconds=0.01,
    )
    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.start(start_context(controller))

    pending: EndConversationRequest | None = None

    def request_arrived() -> bool:
        nonlocal pending
        pending = controller.take_request()
        return pending is not None

    wait_until(request_arrived, delegate)

    assert pending is not None
    assert pending.source is EndSource.DELEGATE
    assert pending.reason == "fixture_complete"
    assert pending.farewell == "Fixture finished."
    delegate.close()
    logger.close()


def test_crashed_process_recovers_to_warm_idle_state(tmp_path) -> None:
    log_path = tmp_path / "events.jsonl"
    logger = EventLogger(log_path)
    controller = ConversationController(logger)
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE), "--crash-on-start"],
        restart_delay_seconds=0.1,
    )
    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.start(start_context(controller))

    wait_until(
        lambda: not delegate.active and delegate.status.health is DelegateHealth.FAILED,
        delegate,
    )
    wait_until(lambda: delegate.status.warm, delegate)

    assert delegate.status.accepting_activation
    delegate.close()
    logger.close()
    records = [json.loads(line) for line in log_path.read_text().splitlines()]
    assert sum(record["event"] == "delegate.process_started" for record in records) >= 2
    assert any(record["event"] == "delegate.process_exited" for record in records)


def test_immediate_end_terminates_and_rewarms_process() -> None:
    logger = EventLogger()
    controller = ConversationController(logger)
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE)],
        restart_delay_seconds=0.01,
    )
    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.start(start_context(controller))

    delegate.request_end(
        EndConversationRequest(
            source=EndSource.USER,
            reason="emergency_stop",
            mode=EndMode.IMMEDIATE,
            requested_at_ns=time.monotonic_ns(),
        )
    )

    assert not delegate.active
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.close()
    logger.close()
