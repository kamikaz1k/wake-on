from __future__ import annotations

import argparse
import os
import signal
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

from .agent import AudioInputOwnership, MockConversationAgent
from .audio import MicrophoneSource, WaveFileSource
from .conversation import ConversationController, EndSource
from .events import EventLogger
from .media_policy import ConversationMediaPolicy, resolve_media_policy
from .native_media import (
    DEFAULT_NATIVE_MEDIA_HELPER,
    NativeMacMedia,
    NativeWakeAudioSource,
)
from .orchestrator import WakeListener
from .process_delegate import ProcessConversationDelegate
from .realtime import DEFAULT_INSTRUCTIONS, OpenAIRealtimeAgent
from .wake import SherpaWakeWordEngine

DEFAULT_MODEL_DIR = Path("models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20")
DEFAULT_KEYWORDS_FILE = Path("models/hey-lobby.txt")
DEFAULT_ROUTE_ID = "lobby"
DEFAULT_TRIGGER_ID = "hey_lobby"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lobby-wake")
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--keywords-file", type=Path, default=DEFAULT_KEYWORDS_FILE)
    parser.add_argument("--audio-file", type=Path, help="Use a mono 16-bit WAV instead of a mic")
    parser.add_argument("--device", help="sounddevice input device name or index")
    parser.add_argument("--preroll-seconds", type=float, default=1.0)
    parser.add_argument("--block-ms", type=int, default=80)
    parser.add_argument("--score", type=float, default=2.0)
    parser.add_argument("--threshold", type=float, default=0.1)
    parser.add_argument("--max-active-paths", type=int, default=16)
    parser.add_argument("--model-chunk", type=int, choices=(8, 16), default=8)
    parser.add_argument(
        "--trailing-blanks",
        type=int,
        choices=range(0, 11),
        default=0,
        help="Sherpa blank frames required after a keyword (default: 0)",
    )
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--model-variant", choices=("int8", "fp32"), default="int8")
    parser.add_argument("--agent", choices=("openai", "mock", "process"), default="openai")
    parser.add_argument("--mock-duration", type=float, default=3.0)
    parser.add_argument(
        "--delegate-audio-input",
        choices=tuple(AudioInputOwnership),
        default=AudioInputOwnership.HARNESS,
        help="Who captures conversation audio for --agent process (default: harness)",
    )
    parser.add_argument(
        "--delegate-command",
        nargs=argparse.REMAINDER,
        help="External delegate executable and arguments; must be the final wake-on option",
    )
    parser.add_argument("--realtime-model", default="gpt-realtime-2.1")
    parser.add_argument("--voice", default="marin")
    parser.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    parser.add_argument("--session-timeout", type=float, default=30.0)
    parser.add_argument(
        "--realtime-vad",
        choices=("server_vad", "semantic_vad"),
        default="server_vad",
    )
    parser.add_argument("--vad-threshold", type=float, default=0.5)
    parser.add_argument("--vad-prefix-ms", type=int, default=300)
    parser.add_argument("--vad-silence-ms", type=int, default=300)
    parser.add_argument(
        "--vad-eagerness",
        choices=("low", "medium", "high", "auto"),
        default="high",
    )
    parser.add_argument(
        "--no-preconnect",
        action="store_true",
        help="Connect only after wake detection for cold-start latency comparisons",
    )
    parser.add_argument("--output-device", help="sounddevice output device name or index")
    parser.add_argument(
        "--media-policy",
        choices=tuple(ConversationMediaPolicy),
        help=(
            "Conversation media behavior (default: raw-full-duplex; use native-aec "
            "to opt into macOS voice processing only while a conversation is active)"
        ),
    )
    parser.add_argument(
        "--conversation-media",
        choices=("raw", "native-macos"),
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--native-media-helper",
        type=Path,
        default=DEFAULT_NATIVE_MEDIA_HELPER,
        help="Path to the compiled native macOS voice-processing helper",
    )
    parser.add_argument(
        "--full-duplex",
        action=argparse.BooleanOptionalAction,
        default=None,
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--log", type=Path, default=Path("latency.jsonl"))
    return parser


def main() -> None:
    load_dotenv()
    parser = build_parser()
    args = parser.parse_args()
    try:
        media_policy = resolve_media_policy(
            args.media_policy,
            legacy_adapter=args.conversation_media,
            legacy_full_duplex=args.full_duplex,
        )
    except ValueError as error:
        parser.error(str(error))
    if args.agent == "process" and not args.delegate_command:
        parser.error("--agent process requires --delegate-command")
    if media_policy.aec_on_demand and args.agent == "mock":
        parser.error("--media-policy native-aec requires a conversation audio backend")
    if media_policy.aec_on_demand and sys.platform != "darwin":
        parser.error("--media-policy native-aec is available only on macOS")
    if media_policy.aec_on_demand and args.output_device is not None:
        parser.error("--output-device is not yet supported by native macOS media")
    if media_policy.aec_on_demand and args.device is not None:
        parser.error("--device is not yet supported by native macOS media")
    if media_policy.aec_on_demand and args.audio_file is not None:
        parser.error("--audio-file cannot be combined with native macOS media")
    device: int | str | None = args.device
    if isinstance(device, str) and device.isdigit():
        device = int(device)
    output_device: int | str | None = args.output_device
    if isinstance(output_device, str) and output_device.isdigit():
        output_device = int(output_device)

    logger = EventLogger(args.log)
    conversation_controller = ConversationController(logger)
    native_media = (
        NativeMacMedia(logger, (args.native_media_helper,))
        if media_policy.aec_on_demand
        else None
    )
    source = (
        WaveFileSource(args.audio_file, args.block_ms, pace_realtime=args.agent != "mock")
        if args.audio_file
        else (
            NativeWakeAudioSource(native_media)
            if native_media is not None
            else MicrophoneSource(block_duration_ms=args.block_ms, device=device)
        )
    )
    model_load_started_ns = time.monotonic_ns()
    detector = SherpaWakeWordEngine(
        args.model_dir,
        args.keywords_file,
        num_threads=args.threads,
        keywords_score=args.score,
        keywords_threshold=args.threshold,
        max_active_paths=args.max_active_paths,
        num_trailing_blanks=args.trailing_blanks,
        model_chunk=args.model_chunk,
        model_variant=args.model_variant,
    )
    logger.emit(
        "wake.engine_ready",
        model_variant=args.model_variant,
        initialization_ms=(time.monotonic_ns() - model_load_started_ns) / 1_000_000,
    )
    if args.agent == "mock":
        agent = MockConversationAgent(logger, duration_seconds=args.mock_duration)
    elif args.agent == "process":
        agent = ProcessConversationDelegate(
            logger,
            args.delegate_command,
            audio_input=(
                AudioInputOwnership.DELEGATE
                if native_media is not None
                else AudioInputOwnership(args.delegate_audio_input)
            ),
            player=native_media,
            capture=native_media,
        )
        if native_media is not None:
            native_media.set_capture_handler(agent.send_captured_audio)
    else:
        agent = OpenAIRealtimeAgent(
            logger,
            api_key=os.environ.get("OPENAI_API_KEY", ""),
            model=args.realtime_model,
            voice=args.voice,
            instructions=args.instructions,
            output_device=output_device,
            inactivity_timeout_seconds=args.session_timeout,
            full_duplex=media_policy.full_duplex,
            preconnect=not args.no_preconnect,
            vad_mode=args.realtime_vad,
            vad_threshold=args.vad_threshold,
            vad_prefix_padding_ms=args.vad_prefix_ms,
            vad_silence_duration_ms=args.vad_silence_ms,
            vad_eagerness=args.vad_eagerness,
            conversation_controller=conversation_controller,
            player=native_media,
            audio_input=(
                AudioInputOwnership.DELEGATE
                if native_media is not None
                else AudioInputOwnership.HARNESS
            ),
            capture=native_media,
        )
        if native_media is not None:
            native_media.set_capture_handler(agent.send_audio)
    orchestrator = WakeListener(
        detector,
        agent,
        logger,
        sample_rate=source.sample_rate,
        trigger_id=DEFAULT_TRIGGER_ID,
        route_id=DEFAULT_ROUTE_ID,
        preroll_seconds=args.preroll_seconds,
        conversation_controller=conversation_controller,
    )

    should_stop = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal should_stop
        should_stop = True

    def emergency_end(_signum: int, _frame: object) -> None:
        orchestrator.request_end(
            source=EndSource.USER,
            reason="emergency_stop",
            immediate=True,
        )

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    if hasattr(signal, "SIGUSR1"):
        signal.signal(signal.SIGUSR1, emergency_end)

    logger.emit(
        "app.started",
        media_policy=media_policy.policy,
        media_adapter=media_policy.adapter,
        full_duplex=media_policy.full_duplex,
        aec_on_demand=media_policy.aec_on_demand,
        source=(
            "wav"
            if args.audio_file
            else "native-macos" if native_media is not None else "microphone"
        ),
        sample_rate=source.sample_rate,
        audio_block_ms=args.block_ms,
        wake_model_chunk=args.model_chunk,
        wake_max_active_paths=args.max_active_paths,
        wake_score=args.score,
        wake_threshold=args.threshold,
        wake_trailing_blanks=args.trailing_blanks,
        model_dir=args.model_dir,
        pid=os.getpid(),
        emergency_end_signal="SIGUSR1" if hasattr(signal, "SIGUSR1") else None,
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
