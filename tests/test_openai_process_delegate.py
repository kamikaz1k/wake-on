from __future__ import annotations

import io
import json

import numpy as np
import pytest

from lobby_wake.agent import (
    DelegateCapabilities,
    DelegateHealth,
    DelegateStatus,
)
from lobby_wake.openai_process_delegate import (
    BridgeLogger,
    OpenAIProcessWorker,
    ProtocolWriter,
    decode_float_audio,
)
from lobby_wake.process_delegate import PROTOCOL_VERSION, encode_float_audio


class FakeRealtimeAgent:
    def __init__(self) -> None:
        self.active = False
        self.prepared = False
        self.audio_samples = 0

    @property
    def capabilities(self) -> DelegateCapabilities:
        return DelegateCapabilities()

    @property
    def status(self) -> DelegateStatus:
        return DelegateStatus(
            DelegateHealth.READY if self.prepared else DelegateHealth.CREATED,
            accepting_activation=self.prepared,
            warm=self.prepared,
        )

    def prepare(self, _context: object) -> None:
        self.prepared = True

    def start(self, context: object) -> None:
        self.active = True
        initial_audio = context.initial_audio  # type: ignore[attr-defined]
        self.audio_samples = initial_audio.size

    def send_audio(self, samples: np.ndarray, _sample_rate: int) -> None:
        self.audio_samples += samples.size

    def poll(self) -> None:
        pass

    def request_end(self, _request: object) -> None:
        self.active = False

    def stop(self) -> None:
        self.active = False

    def close(self) -> None:
        self.active = False


def test_protocol_writer_and_bridge_logger_emit_versioned_event() -> None:
    stream = io.StringIO()
    writer = ProtocolWriter(stream)
    logger = BridgeLogger(writer)

    emitted_at_ns = logger.emit("agent.first_response_received", latency_ms=12.5)
    writer.close()

    message = json.loads(stream.getvalue())
    assert emitted_at_ns > 0
    assert message == {
        "v": PROTOCOL_VERSION,
        "type": "event",
        "event": "agent.first_response_received",
        "fields": {"latency_ms": 12.5},
        "child_monotonic_ns": emitted_at_ns,
    }


def test_decode_float_audio_validates_sample_count() -> None:
    encoded = encode_float_audio(np.array([-1.0, 0.25], dtype=np.float32))

    np.testing.assert_array_equal(decode_float_audio(encoded), [-1.0, 0.25])
    encoded["samples"] = 3
    with pytest.raises(ValueError, match="sample count"):
        decode_float_audio(encoded)


def test_worker_runs_openai_agent_behind_process_protocol() -> None:
    stream = io.StringIO()
    writer = ProtocolWriter(stream)
    fake_agent = FakeRealtimeAgent()
    worker = OpenAIProcessWorker(
        writer,
        lambda _logger, _controller: fake_agent,  # type: ignore[arg-type,return-value]
    )
    activation_id = "activation-1"
    audio = encode_float_audio(np.ones(160, dtype=np.float32))

    worker.handle(
        {
            "v": PROTOCOL_VERSION,
            "type": "prepare",
            "sample_rate": 16_000,
            "audio_input": "harness",
        }
    )
    worker.handle(
        {
            "v": PROTOCOL_VERSION,
            "type": "start",
            "activation_id": activation_id,
            "wake": {"phrase": "HEY LOBBY", "detected_at_ns": 1},
            "sample_rate": 16_000,
            "initial_audio": audio,
        }
    )
    worker.handle(
        {
            "v": PROTOCOL_VERSION,
            "type": "audio",
            "activation_id": activation_id,
            "sample_rate": 16_000,
            "audio": encode_float_audio(np.ones(80, dtype=np.float32)),
        }
    )
    worker.handle(
        {
            "v": PROTOCOL_VERSION,
            "type": "request_end",
            "activation_id": activation_id,
            "source": "user",
            "reason": "done",
            "mode": "graceful",
            "farewell": None,
        }
    )
    worker.poll()
    worker.close()
    writer.close()

    messages = [json.loads(line) for line in stream.getvalue().splitlines()]
    assert fake_agent.prepared
    assert fake_agent.audio_samples == 240
    assert any(message["type"] == "started" for message in messages)
    assert any(message["type"] == "ended" for message in messages)
    assert messages[-1]["type"] == "status"
    assert messages[-1]["health"] == "closed"
