from __future__ import annotations

import argparse
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from collections.abc import Mapping
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.resources import files
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

from .events import EventLogger
from .realtime import DEFAULT_INSTRUCTIONS

OPENAI_REALTIME_CALLS_URL = "https://api.openai.com/v1/realtime/calls"
MAX_SDP_BYTES = 1_000_000
MAX_TELEMETRY_BYTES = 64_000
DEFAULT_LOG_PATH = Path("webrtc-aec-spike.jsonl")


def build_session_config(
    *,
    model: str,
    voice: str,
    instructions: str,
    vad_threshold: float,
    vad_prefix_padding_ms: int,
    vad_silence_duration_ms: int,
) -> dict[str, Any]:
    return {
        "type": "realtime",
        "model": model,
        "instructions": instructions,
        "audio": {
            "input": {
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": vad_threshold,
                    "prefix_padding_ms": vad_prefix_padding_ms,
                    "silence_duration_ms": vad_silence_duration_ms,
                    "create_response": True,
                    "interrupt_response": True,
                }
            },
            "output": {"voice": voice},
        },
    }


def encode_multipart(fields: Mapping[str, str]) -> tuple[bytes, str]:
    boundary = f"wake-on-{secrets.token_hex(16)}"
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.extend(
            (
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode(),
                b"\r\n",
            )
        )
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def sanitize_telemetry(payload: object) -> tuple[str, dict[str, str | int | float | bool]]:
    if not isinstance(payload, dict):
        raise ValueError("telemetry must be an object")
    event = payload.get("event")
    fields = payload.get("fields", {})
    if not isinstance(event, str) or not event.startswith("webrtc.") or len(event) > 80:
        raise ValueError("telemetry event must use the webrtc.* namespace")
    if not isinstance(fields, dict) or len(fields) > 24:
        raise ValueError("telemetry fields must be a small object")

    sanitized: dict[str, str | int | float | bool] = {}
    for key, value in fields.items():
        if not isinstance(key, str) or not key.replace("_", "").isalnum():
            raise ValueError("telemetry field names must be alphanumeric")
        if not isinstance(value, str | int | float | bool):
            continue
        if isinstance(value, str):
            value = value[:500]
        sanitized[key] = value
    return event, sanitized


class SpikeServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        *,
        api_key: str,
        session_config: dict[str, Any],
        safety_identifier: str | None,
        logger: EventLogger,
    ) -> None:
        super().__init__(server_address, SpikeRequestHandler)
        self.api_key = api_key
        self.session_config = session_config
        self.safety_identifier = safety_identifier
        self.event_logger = logger


class SpikeRequestHandler(BaseHTTPRequestHandler):
    server: SpikeServer

    def do_GET(self) -> None:  # noqa: N802
        if self.path not in {"/", "/index.html"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        html = files("lobby_wake").joinpath("webrtc_spike.html").read_bytes()
        self._send_bytes(HTTPStatus.OK, html, "text/html; charset=utf-8")

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/session":
            self._create_session()
            return
        if self.path == "/telemetry":
            self._record_telemetry()
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _create_session(self) -> None:
        try:
            offer_sdp = self._read_body(MAX_SDP_BYTES).decode("utf-8")
        except (UnicodeDecodeError, ValueError) as error:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        if not offer_sdp.startswith("v=0"):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "body is not SDP"})
            return

        started_ns = self.server.event_logger.emit(
            "webrtc.session_requested",
            model=self.server.session_config["model"],
        )
        body, content_type = encode_multipart(
            {
                "sdp": offer_sdp,
                "session": json.dumps(self.server.session_config, separators=(",", ":")),
            }
        )
        headers = {
            "Authorization": f"Bearer {self.server.api_key}",
            "Content-Type": content_type,
        }
        if self.server.safety_identifier:
            headers["OpenAI-Safety-Identifier"] = self.server.safety_identifier
        request = urllib.request.Request(
            OPENAI_REALTIME_CALLS_URL,
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                answer_sdp = response.read(MAX_SDP_BYTES + 1)
                if len(answer_sdp) > MAX_SDP_BYTES:
                    raise ValueError("OpenAI SDP response is too large")
        except urllib.error.HTTPError as error:
            detail = error.read(4_096).decode("utf-8", errors="replace")
            self.server.event_logger.emit(
                "webrtc.session_error",
                status=error.code,
                detail=detail,
            )
            self._send_json(
                HTTPStatus.BAD_GATEWAY,
                {"error": "OpenAI rejected the WebRTC session", "status": error.code},
            )
            return
        except (OSError, ValueError) as error:
            self.server.event_logger.emit("webrtc.session_error", detail=str(error))
            self._send_json(HTTPStatus.BAD_GATEWAY, {"error": "WebRTC session failed"})
            return

        self.server.event_logger.emit(
            "webrtc.session_ready",
            setup_ms=(time.monotonic_ns() - started_ns) / 1_000_000,
        )
        self._send_bytes(HTTPStatus.OK, answer_sdp, "application/sdp")

    def _record_telemetry(self) -> None:
        try:
            payload = json.loads(self._read_body(MAX_TELEMETRY_BYTES))
            event, fields = sanitize_telemetry(payload)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        self.server.event_logger.emit(event, **fields)
        self._send_json(HTTPStatus.NO_CONTENT, None)

    def _read_body(self, maximum: int) -> bytes:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise ValueError("Content-Length is invalid") from error
        if length < 0 or length > maximum:
            raise ValueError("request body is too large")
        return self.rfile.read(length)

    def _send_json(self, status: HTTPStatus, payload: object) -> None:
        body = b"" if payload is None else json.dumps(payload).encode()
        self._send_bytes(status, body, "application/json")

    def _send_bytes(self, status: HTTPStatus, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'",
        )
        self.end_headers()
        self.wfile.write(body)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="lobby-webrtc-aec-spike",
        description="Run a loopback-only browser spike for laptop WebRTC echo cancellation.",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", default="gpt-realtime-2.1")
    parser.add_argument("--voice", default="marin")
    parser.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    parser.add_argument("--vad-threshold", type=float, default=0.5)
    parser.add_argument("--vad-prefix-ms", type=int, default=300)
    parser.add_argument("--vad-silence-ms", type=int, default=300)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG_PATH)
    parser.add_argument("--no-open", action="store_true", help="Do not open the browser")
    return parser


def main() -> None:
    load_dotenv()
    args = build_parser().parse_args()
    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("The AEC spike only permits a loopback host")
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise SystemExit("OPENAI_API_KEY is required in the environment or .env")

    logger = EventLogger(args.log)
    server = SpikeServer(
        (args.host, args.port),
        api_key=api_key,
        session_config=build_session_config(
            model=args.model,
            voice=args.voice,
            instructions=args.instructions,
            vad_threshold=args.vad_threshold,
            vad_prefix_padding_ms=args.vad_prefix_ms,
            vad_silence_duration_ms=args.vad_silence_ms,
        ),
        safety_identifier=os.environ.get("OPENAI_SAFETY_IDENTIFIER"),
        logger=logger,
    )
    host, port = server.server_address[:2]
    url = f"http://{host}:{port}"
    logger.emit("webrtc.spike_started", url=url, log=args.log)
    if not args.no_open:
        threading.Timer(0.2, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        logger.emit("webrtc.spike_stopped")
        logger.close()


if __name__ == "__main__":
    main()
