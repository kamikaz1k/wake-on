from __future__ import annotations

import argparse
import os
import signal
import time
from pathlib import Path

from dotenv import load_dotenv

from .agent import MockConversationAgent
from .audio import MicrophoneSource, WaveFileSource
from .events import EventLogger
from .orchestrator import Orchestrator
from .realtime import DEFAULT_INSTRUCTIONS, OpenAIRealtimeAgent
from .wake import SherpaWakeWordEngine

DEFAULT_MODEL_DIR = Path("models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
DEFAULT_KEYWORDS_FILE = Path("models/hey-lobby.txt")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-wake")
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--keywords-file", type=Path, default=DEFAULT_KEYWORDS_FILE)
    parser.add_argument("--audio-file", type=Path, help="Use a mono 16-bit WAV instead of a mic")
    parser.add_argument("--device", help="sounddevice input device name or index")
    parser.add_argument("--preroll-seconds", type=float, default=1.0)
    parser.add_argument("--block-ms", type=int, default=80)
    parser.add_argument("--score", type=float, default=1.5)
    parser.add_argument("--threshold", type=float, default=0.25)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--model-variant", choices=("int8", "fp32"), default="int8")
    parser.add_argument("--agent", choices=("openai", "mock"), default="openai")
    parser.add_argument("--mock-duration", type=float, default=3.0)
    parser.add_argument("--realtime-model", default="gpt-realtime-2.1")
    parser.add_argument("--voice", default="marin")
    parser.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    parser.add_argument("--session-timeout", type=float, default=30.0)
    parser.add_argument(
        "--no-preconnect",
        action="store_true",
        help="Connect only after wake detection for cold-start latency comparisons",
    )
    parser.add_argument("--output-device", help="sounddevice output device name or index")
    parser.add_argument(
        "--full-duplex",
        action="store_true",
        help="Send mic audio during playback (use headphones to avoid echo)",
    )
    parser.add_argument("--log", type=Path, default=Path("latency.jsonl"))
    return parser


def main() -> None:
    load_dotenv()
    args = build_parser().parse_args()
    device: int | str | None = args.device
    if isinstance(device, str) and device.isdigit():
        device = int(device)
    output_device: int | str | None = args.output_device
    if isinstance(output_device, str) and output_device.isdigit():
        output_device = int(output_device)

    logger = EventLogger(args.log)
    source = (
        WaveFileSource(args.audio_file, args.block_ms, pace_realtime=args.agent == "openai")
        if args.audio_file
        else MicrophoneSource(block_duration_ms=args.block_ms, device=device)
    )
    model_load_started_ns = time.monotonic_ns()
    detector = SherpaWakeWordEngine(
        args.model_dir,
        args.keywords_file,
        num_threads=args.threads,
        keywords_score=args.score,
        keywords_threshold=args.threshold,
        model_variant=args.model_variant,
    )
    logger.emit(
        "wake.engine_ready",
        model_variant=args.model_variant,
        initialization_ms=(time.monotonic_ns() - model_load_started_ns) / 1_000_000,
    )
    if args.agent == "mock":
        agent = MockConversationAgent(logger, duration_seconds=args.mock_duration)
    else:
        agent = OpenAIRealtimeAgent(
            logger,
            api_key=os.environ.get("OPENAI_API_KEY", ""),
            model=args.realtime_model,
            voice=args.voice,
            instructions=args.instructions,
            output_device=output_device,
            inactivity_timeout_seconds=args.session_timeout,
            full_duplex=args.full_duplex,
            preconnect=not args.no_preconnect,
        )
    orchestrator = Orchestrator(
        detector,
        agent,
        logger,
        sample_rate=source.sample_rate,
        preroll_seconds=args.preroll_seconds,
    )

    should_stop = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal should_stop
        should_stop = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    logger.emit(
        "app.started",
        source="wav" if args.audio_file else "microphone",
        sample_rate=source.sample_rate,
        model_dir=args.model_dir,
    )
    orchestrator.prepare()
    try:
        for samples in source.frames():
            orchestrator.process(samples)
            if should_stop:
                break
    finally:
        orchestrator.close()
        source.close()
        logger.emit("app.stopped")
        logger.close()


if __name__ == "__main__":
    main()
