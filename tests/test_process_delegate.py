from __future__ import annotations

import base64
import json
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path

import numpy as np

from lobby_wake.agent import (
    AudioInputOwnership,
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
from lobby_wake.playback import PlaybackPosition
from lobby_wake.process_delegate import ProcessConversationDelegate, encode_float_audio

FIXTURE = Path(__file__).parent / "fixtures" / "process_delegate.py"


class FakeHarnessMedia:
    sample_rate = 24_000

    def __init__(self) -> None:
        self.started = False
        self.playing = False
        self.capture_active = False
        self.chunks: list[bytes] = []
        self.clear_count = 0
        self.deactivate_thread_ids: list[int] = []

    def start(self) -> None:
        self.started = True

    def enqueue(
        self,
        pcm16: bytes,
        on_start: Callable[[], None] | None = None,
        *,
        item_id: str = "",
        content_index: int = 0,
    ) -> None:
        del item_id, content_index
        self.chunks.append(pcm16)
        self.playing = True
        if on_start is not None:
            on_start()

    def clear(self) -> None:
        self.clear_count += 1
        self.playing = False

    def interrupt(
        self,
        item_id: str | None = None,
        content_index: int = 0,
    ) -> PlaybackPosition | None:
        self.clear()
        return (
            PlaybackPosition(item_id, content_index, 0)
            if item_id is not None
            else None
        )

    def close(self) -> None:
        self.started = False

    def activate_capture(self) -> None:
        self.capture_active = True

    def deactivate_capture(self) -> None:
        self.deactivate_thread_ids.append(threading.get_ident())
        self.capture_active = False


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


def test_process_delegate_routes_capture_and_playback_through_harness_media() -> None:
    logger = EventLogger()
    controller = ConversationController(logger)
    media = FakeHarnessMedia()
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE), "--emit-playback"],
        audio_input=AudioInputOwnership.DELEGATE,
        player=media,
        capture=media,
        restart_delay_seconds=0.01,
    )

    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.start(start_context(controller))
    delegate.send_captured_audio(np.ones(80, dtype=np.float32), 24_000)
    wait_until(lambda: bool(media.chunks), delegate)

    assert media.started
    assert media.capture_active
    assert media.chunks == [b"\x01\x00\x02\x00"]

    delegate.stop()
    assert not media.capture_active
    assert not media.playing
    delegate.close()
    logger.close()


def test_process_delegate_defers_child_ended_media_teardown_to_poll_thread() -> None:
    logger = EventLogger()
    controller = ConversationController(logger)
    media = FakeHarnessMedia()
    delegate = ProcessConversationDelegate(
        logger,
        [sys.executable, str(FIXTURE)],
        audio_input=AudioInputOwnership.DELEGATE,
        player=media,
        capture=media,
        restart_delay_seconds=0.01,
    )
    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_until(lambda: delegate.status.warm, delegate)
    delegate.start(start_context(controller))
    delegate.request_end(
        EndConversationRequest(
            source=EndSource.USER,
            reason="done",
            mode=EndMode.GRACEFUL,
            requested_at_ns=time.monotonic_ns(),
        )
    )

    deadline = time.monotonic() + 2
    while delegate.active and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not delegate.active
    assert media.capture_active

    poll_thread_id = threading.get_ident()
    delegate.poll()
    assert not media.capture_active
    assert media.deactivate_thread_ids == [poll_thread_id]
    delegate.close()
    logger.close()


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
