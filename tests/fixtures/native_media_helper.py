from __future__ import annotations

import json
import struct
import sys

HEADER = struct.Struct(">cI")
CHUNK_ID = struct.Struct(">Q")


def write_frame(frame_type: bytes, payload: bytes = b"") -> None:
    sys.stdout.buffer.write(HEADER.pack(frame_type, len(payload)) + payload)
    sys.stdout.buffer.flush()


def read_exactly(count: int) -> bytes | None:
    data = bytearray()
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


write_frame(
    b"R",
    json.dumps(
        {
            "capture_sample_rate": 48_000,
            "capture_channels": 1,
            "wake_sample_rate": 16_000,
            "playback_sample_rate": 24_000,
            "output_latency_ms": 12.5,
            "mode": "raw",
            "voice_processing": False,
            "voice_processing_agc": True,
            "other_audio_ducking": "off",
        }
    ).encode(),
)
write_frame(b"A", struct.pack("<hhh", -32_768, 0, 32_767))
write_frame(b"W", struct.pack("<h", -32_768))

while header := read_exactly(HEADER.size):
    frame_type, length = HEADER.unpack(header)
    payload = read_exactly(length)
    if payload is None:
        break
    if frame_type == b"P":
        write_frame(b"D", payload[: CHUNK_ID.size])
    elif frame_type == b"V":
        active = True
        write_frame(
            b"S",
            json.dumps(
                {
                    "mode": "aec" if active else "raw",
                    "capture_sample_rate": 48_000,
                    "wake_sample_rate": 16_000,
                    "playback_sample_rate": 24_000,
                    "output_latency_ms": 12.5,
                    "voice_processing": active,
                    "voice_processing_agc": True,
                    "other_audio_ducking": "minimum" if active else "off",
                }
            ).encode(),
        )
        if active:
            write_frame(b"A", struct.pack("<hhh", -32_768, 0, 32_767))
    elif frame_type == b"Q":
        break
