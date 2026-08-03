from __future__ import annotations

import argparse
import statistics
import sys
import threading
import time
from pathlib import Path
from typing import Any

import numpy as np

from lobby_wake.agent import DelegatePrepareContext, DelegateStartContext
from lobby_wake.conversation import (
    ConversationController,
    EndConversationRequest,
    EndMode,
    EndSource,
)
from lobby_wake.events import WakeEvent
from lobby_wake.process_delegate import ProcessConversationDelegate
from lobby_wake.realtime import OpenAIRealtimeAgent


class CaptureLogger:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.events: list[tuple[str, dict[str, Any]]] = []

    def emit(self, event: str, **fields: Any) -> int:
        now_ns = time.monotonic_ns()
        with self._lock:
            self.events.append((event, fields))
        return now_ns

    def values(self, event: str, field: str) -> list[float]:
        with self._lock:
            return [
                float(fields[field])
                for name, fields in self.events
                if name == event and fields.get(field) is not None
            ]


class FakeSocket:
    def send(self, _message: str) -> None:
        pass

    def close(self) -> None:
        pass


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    index = round((len(ordered) - 1) * quantile)
    return ordered[index]


def render(label: str, values: list[float]) -> str:
    return (
        f"{label}: n={len(values)} "
        f"p50={statistics.median(values):.3f} ms "
        f"p95={percentile(values, 0.95):.3f} ms "
        f"max={max(values):.3f} ms"
    )


def context(
    controller: ConversationController,
    samples: np.ndarray,
) -> DelegateStartContext:
    controller.finish()
    controller.begin()
    return DelegateStartContext(
        wake=WakeEvent("HEY LOBBY", time.monotonic_ns()),
        conversation=controller.handle,
        sample_rate=16_000,
        initial_audio=samples,
    )


def benchmark_direct(iterations: int, samples: np.ndarray) -> list[float]:
    logger = CaptureLogger()
    controller = ConversationController(logger)  # type: ignore[arg-type]
    agent = OpenAIRealtimeAgent(logger, api_key="benchmark", preconnect=False)  # type: ignore[arg-type]
    socket = FakeSocket()
    durations: list[float] = []
    for _ in range(iterations):
        agent._prepared = True
        agent._ready = True
        agent._ws = socket
        agent._ready_at_ns = time.monotonic_ns()
        activation = context(controller, samples)
        started_ns = time.monotonic_ns()
        agent.start(activation)
        durations.append((time.monotonic_ns() - started_ns) / 1_000_000)
        with agent._state_lock:
            agent._active = False
            agent._started_at_ns = None
    agent.close()
    return durations


def wait_for(condition: Any, delegate: ProcessConversationDelegate) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        delegate.poll()
        if condition():
            return
        time.sleep(0.001)
    raise RuntimeError("delegate benchmark timed out")


def benchmark_process(
    iterations: int,
    samples: np.ndarray,
) -> tuple[list[float], list[float]]:
    logger = CaptureLogger()
    controller = ConversationController(logger)  # type: ignore[arg-type]
    fixture = Path(__file__).parents[1] / "tests" / "fixtures" / "process_delegate.py"
    delegate = ProcessConversationDelegate(
        logger,  # type: ignore[arg-type]
        [sys.executable, str(fixture)],
        restart_delay_seconds=0.01,
    )
    delegate.prepare(DelegatePrepareContext(sample_rate=16_000))
    wait_for(lambda: delegate.status.warm, delegate)
    start_calls: list[float] = []
    for index in range(iterations):
        activation = context(controller, samples)
        started_ns = time.monotonic_ns()
        delegate.start(activation)
        start_calls.append((time.monotonic_ns() - started_ns) / 1_000_000)
        wait_for(
            lambda expected_index=index: len(
                logger.values("delegate.activation_started", "activation_dispatch_ms")
            )
            > expected_index,
            delegate,
        )
        delegate.request_end(
            EndConversationRequest(
                source=EndSource.SYSTEM,
                reason="benchmark_iteration",
                mode=EndMode.GRACEFUL,
                requested_at_ns=time.monotonic_ns(),
            )
        )
        wait_for(lambda: not delegate.active, delegate)
    dispatch = logger.values("delegate.activation_started", "activation_dispatch_ms")
    delegate.close()
    return start_calls, dispatch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--preroll-ms", type=int, default=1000)
    args = parser.parse_args()
    if args.iterations <= 0 or args.preroll_ms < 0:
        parser.error("iterations must be positive and preroll must be non-negative")
    samples = np.zeros(round(16_000 * args.preroll_ms / 1000), dtype=np.float32)

    direct = benchmark_direct(args.iterations, samples)
    process_start, process_dispatch = benchmark_process(args.iterations, samples)

    print(render("In-process OpenAI warm start() call", direct))
    print(render("Process delegate start() call", process_start))
    print(render("Process delegate parent-to-child started ack", process_dispatch))
    print("Synthetic local benchmark only; it excludes wake detection and backend response time.")


if __name__ == "__main__":
    main()
