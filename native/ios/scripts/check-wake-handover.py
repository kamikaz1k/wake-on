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
  FAIL  echo cancellation switched on at session start instead of waiting for Lobby's reply
        (no `voice_processing_deferred`): switching silences the mic ~0.3 s, mid-sentence
  FAIL  the call's audio engine started before the user paused (no `audio_start_after_pause`):
        starting it mutes the iPhone's microphone ~0.5 s, mid-sentence
  WARN  the user asked to play/pause/stop/skip something but no tool was called
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
    if "voice_processing_on" in joined and "voice_processing_deferred" not in joined:
        failures.append("echo cancellation switched on at session start, not after Lobby's reply "
                        "(silences the mic ~0.3 s mid-sentence)")
    if "mic_live" in joined and "audio_start_after_pause" not in joined:
        failures.append("call audio engine started before the user paused (mutes the mic ~0.5 s)")
    started = re.search(r"audio_start_after_pause reason=(\S+) afterMs=(-?\d+)", joined)
    if started:
        facts["pause"] = f"{started[1]} at {started[2]} ms"
    said_text = " ".join(line.split("You:", 1)[1] for line in body if line.startswith("VOICE transcript You:")).lower()
    if re.search(r"\b(play|pause|stop|skip|resume)\b", said_text) and "function_call" not in joined:
        warnings.append("asked to play/pause/stop/skip but no tool was called")
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
            print(f"{Path(path).name} call {number}: {verdict}  app {facts['app']}, audio start "
                  f"{facts.get('pause', '?')}, mic live "
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
