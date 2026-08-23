from __future__ import annotations

import argparse
import base64
import json
import os
import sys

PROTOCOL_VERSION = 1


def emit(message_type: str, **fields: object) -> None:
    print(
        json.dumps({"v": PROTOCOL_VERSION, "type": message_type, **fields}),
        flush=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request-end", action="store_true")
    parser.add_argument("--crash-on-start", action="store_true")
    parser.add_argument("--emit-playback", action="store_true")
    args = parser.parse_args()

    for line in sys.stdin:
        message = json.loads(line)
        message_type = message["type"]
        if message_type == "prepare":
            emit(
                "status",
                health="ready",
                accepting_activation=True,
                warm=True,
                detail="fixture ready",
            )
        elif message_type == "start":
            activation_id = message["activation_id"]
            initial_audio = message.get("initial_audio") or {}
            emit("started", activation_id=activation_id)
            emit(
                "event",
                event="agent.fixture_started",
                fields={"fixture": True},
            )
            emit(
                "log",
                message="activation received",
                fields={"initial_audio_samples": initial_audio.get("samples", 0)},
            )
            if args.emit_playback:
                emit(
                    "playback_audio",
                    activation_id=activation_id,
                    item_id="fixture-item",
                    content_index=0,
                    audio={
                        "encoding": "pcm16le",
                        "samples": 2,
                        "data": base64.b64encode(b"\x01\x00\x02\x00").decode(),
                    },
                )
            if args.request_end:
                emit(
                    "request_end",
                    activation_id=activation_id,
                    reason="fixture_complete",
                    farewell="Fixture finished.",
                    immediate=False,
                )
            if args.crash_on_start:
                os._exit(17)
        elif message_type == "audio":
            emit(
                "log",
                message="audio received",
                fields={"audio_samples": message["audio"]["samples"]},
            )
        elif message_type in {"request_end", "stop"}:
            emit(
                "ended",
                activation_id=message["activation_id"],
                reason=message.get("reason", message_type),
            )
        elif message_type == "close":
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
