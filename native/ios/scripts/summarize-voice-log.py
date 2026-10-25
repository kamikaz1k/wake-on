#!/usr/bin/env python3
"""Turn Wake On voice-console logs into one CSV row per call.

Usage: summarize-voice-log.py LOG [LOG ...] > calls.csv

Debug builds append `VOICE ...` lines to Documents/voice-console.log. Each call starts
with `VOICE start trigger=<name>`; milestones are `VOICE mark <name> <ms>ms`, measured
from the trigger. Older logs (before local buffering) used "listening" for "server ready
and microphone packets leaving the phone". That is reported here as
`reaching_openai_ms`. Newer logs use `mic_live` for "microphone capturing" and
`audio_reaching_openai` for the network milestone.
"""
import csv
import re
import sys
from pathlib import Path

MARKS = [
    "key_loaded", "http_request_begin", "http_response", "remote_description_set",
    "ice_connected", "data_channel_open", "session_started", "first_microphone_packet_sent",
    "first_audio_packet_received", "audio_armed", "first_frame_after_trigger",
    "app_became_active", "mic_live", "audio_reaching_openai", "backlog_sent",
]
FIELDS = ["file", "call", "trigger", "after_app_launch"] + [f"{m}_ms" for m in MARKS] + [
    "server_wait_ms", "reused_connection", "candidates", "mic_live_ms", "reaching_openai_ms",
    "ready_ms", "backlog_ms", "user_said", "assistant_said", "server_events", "ended",
]
MARK = re.compile(r"^VOICE mark (\S+) ([\d.]+)ms(.*)$")


def calls(path):
    lines = path.read_text(errors="replace").splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("VOICE start trigger=")]
    for number, start in enumerate(starts, 1):
        end = starts[number] if number < len(starts) else len(lines)
        before = lines[max(0, start - 8):start]
        body = lines[start:end]
        row = {"file": path.name, "call": number,
               "trigger": body[0].split("trigger=", 1)[1].strip(),
               "after_app_launch": any("app_launch" in line for line in before)}
        user, assistant = [], []
        for line in body:
            match = MARK.match(line)
            if match:
                name, ms, rest = match.group(1), float(match.group(2)), match.group(3)
                if name in MARKS and f"{name}_ms" not in row:
                    row[f"{name}_ms"] = round(ms, 1)
                if name == "http_response":
                    for key, column in [("serverWaitMs", "server_wait_ms"), ("reusedConnection", "reused_connection")]:
                        found = re.search(rf"{key}=(\S+)", rest)
                        if found:
                            value = found.group(1)
                            row[column] = round(float(value)) if column == "server_wait_ms" else value
                if name == "ice_gathering_done" or name == "offer_reused":
                    found = re.search(r"candidates=(\d+)", rest)
                    if found:
                        row["candidates"] = int(found.group(1))
                if name == "backlog_sent":
                    found = re.search(r"backlogMs=([\d.]+)", rest)
                    if found:
                        row["backlog_ms"] = round(float(found.group(1)))
                continue
            for pattern, column in [(r"triggerToMicLiveMs=(\d+)", "mic_live_ms"),
                                    (r"triggerToReachingOpenAIMs=(\d+)", "reaching_openai_ms"),
                                    (r"setup readyMs=(\d+)", "ready_ms")]:
                found = re.search(pattern, line)
                if found:
                    row[column] = int(found.group(1))
            legacy = re.search(r"VOICE listening triggerToListeningMs=(\d+)", line)
            if legacy and "mic_live_ms" not in row and not any("mic_live" in b for b in body):
                row["reaching_openai_ms"] = int(legacy.group(1))
            if line.startswith("VOICE transcript You:"):
                user.append(line.split(":", 1)[1].strip())
            if line.startswith("VOICE transcript Lobby:"):
                assistant.append(line.split(":", 1)[1].strip())
            if line.startswith("VOICE server_events "):
                row["server_events"] = line.split(" ", 2)[2]
            if line.startswith("VOICE ended "):
                row["ended"] = line.split("ended ", 1)[1]
        row["user_said"] = " ".join(user)
        row["assistant_said"] = " ".join(assistant)
        yield row


def main(paths):
    writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS, extrasaction="ignore")
    writer.writeheader()
    for path in paths:
        for row in calls(Path(path)):
            writer.writerow(row)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
