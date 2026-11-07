#!/usr/bin/env python3
"""Check every "Hey Lobby" call in a phone voice log for a broken handover.

Words said straight after "Hey Lobby" must reach the call. This broke several times, and
the unit tests (Tests/WakeHandoverTests.swift) can't see device-only causes, so run this on
the phone's log after testing "Hey Lobby, <request>" with the app on screen and in the background:

  xcrun devicectl device copy from ... --source Documents/voice-console.log --destination log.txt
  python3 scripts/check-wake-handover.py log.txt

Exit status 1 if any wake call FAILs. Per call:
  FAIL  the call switched the audio session (`session_configure`) instead of keeping the
        listener's: the switch took ~1 s and the listener recorded silence meanwhile
  FAIL  no `wake bridge merged`: the listener's audio never reached the call
  WARN  microphone live more than 700 ms after the wake (old foreground path: ~1,100 ms)
  WARN  the staged audio ended in near silence (tailDb <= -100); fine if the user paused,
        suspicious if words went missing
"""
import re
import sys
from pathlib import Path

MIC_LIVE_WARN_MS = 700


def wake_calls(text):
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("VOICE start trigger=")]
    for number, start in enumerate(starts, 1):
        end = starts[number] if number < len(starts) else len(lines)
        if lines[start].strip().endswith("trigger=wake_word"):
            yield number, lines[start:end]


def check(body):
    """(failures, warnings, facts) for one wake call's log lines."""
    joined = "\n".join(body)
    failures, warnings = [], []
    facts = {}
    state = re.search(r"wake_word_talk appState=(\d)", joined)
    facts["app"] = {"0": "on screen", "1": "inactive", "2": "background"}.get(state[1], "?") if state else "?"
    if "session_configure" in joined:
        failures.append("switched the audio session instead of keeping the listener's (session_configure)")
    bridge = re.search(r"wake bridge merged bridgeMs=(\d+) seamGapMs=\S+ tailDb=(-?\d+)", joined)
    if not bridge:
        failures.append("listener audio never reached the call (no 'wake bridge merged')")
    else:
        facts["bridge_ms"] = int(bridge[1])
        if int(bridge[2]) <= -100:
            warnings.append(f"staged audio ended in near silence (tailDb={bridge[2]})")
    mic = re.search(r"mic_live triggerToMicLiveMs=(\d+)", joined)
    if mic:
        facts["mic_live_ms"] = int(mic[1])
        if int(mic[1]) > MIC_LIVE_WARN_MS:
            warnings.append(f"microphone live {mic[1]} ms after the wake (expected under {MIC_LIVE_WARN_MS})")
    said = [line.split("You:", 1)[1].strip() for line in body if line.startswith("VOICE transcript You:")]
    facts["first_words"] = said[0] if said else ""
    return failures, warnings, facts


def main(paths):
    failed = False
    total = 0
    for path in paths:
        for number, body in wake_calls(Path(path).read_text(errors="replace")):
            total += 1
            failures, warnings, facts = check(body)
            verdict = "FAIL" if failures else ("WARN" if warnings else "ok")
            failed |= bool(failures)
            print(f"{Path(path).name} call {number}: {verdict}  app {facts['app']}, mic live "
                  f"{facts.get('mic_live_ms', '?')} ms, bridge {facts.get('bridge_ms', '?')} ms, "
                  f"heard {facts['first_words']!r}")
            for reason in failures:
                print(f"    FAIL {reason}")
            for reason in warnings:
                print(f"    WARN {reason}")
    if total == 0:
        print("No Hey Lobby calls in the log.")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
