"""The phone-log checker for the Hey Lobby handover (native/ios/scripts/check-wake-handover.py)."""
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "native/ios/scripts/check-wake-handover.py"
spec = importlib.util.spec_from_file_location("check_wake_handover", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

# Excerpts from real phone logs, 2026-11-07.
BROKEN_FOREGROUND = """\
VOICE start trigger=wake_word
VOICE @363520ms wake_word_talk appState=0
VOICE mark device:session_configure 0.8ms detail=session_configure backgroundStart=false wasActiveCategory=AVAudioSessionCategoryPlayAndRecord mode=AVAudioSessionModeDefault
VOICE mic_live triggerToMicLiveMs=1094
VOICE wake bridge merged bridgeMs=1426 seamGapMs=0.0 tailDb=-120
VOICE transcript You:  away with
VOICE ended reason=close_requested callMs=6346 usageSeconds=15.0
"""
GOOD_BACKGROUND = """\
VOICE start trigger=wake_word
VOICE @1060871ms wake_word_talk appState=2
VOICE mark device:session_kept 2.2ms detail=session_kept category=AVAudioSessionCategoryPlayAndRecord mode=AVAudioSessionModeDefault options=41 outputs=Speaker
VOICE mic_live triggerToMicLiveMs=392
VOICE wake bridge merged bridgeMs=736 seamGapMs=0.0 tailDb=-60
VOICE transcript You:  What's up
VOICE ended reason=close_requested callMs=13832 usageSeconds=15.0
"""
ACTION_BUTTON = """\
VOICE start trigger=app_intent_fast
VOICE mark device:session_configure 0.8ms detail=session_configure backgroundStart=false
VOICE mic_live triggerToMicLiveMs=300
"""


def test_session_switch_in_a_wake_call_fails():
    [(number, body)] = list(checker.wake_calls(BROKEN_FOREGROUND))
    failures, warnings, facts = checker.check(body)
    assert any("session_configure" in reason for reason in failures)
    assert any("1094 ms" in reason for reason in warnings)
    assert facts["app"] == "on screen"
    assert facts["first_words"] == "away with"


def test_kept_session_passes():
    [(number, body)] = list(checker.wake_calls(GOOD_BACKGROUND))
    failures, warnings, facts = checker.check(body)
    assert failures == [] and warnings == []
    assert facts["mic_live_ms"] == 392


def test_missing_bridge_fails():
    body = GOOD_BACKGROUND.replace("VOICE wake bridge merged bridgeMs=736 seamGapMs=0.0 tailDb=-60\n", "")
    [(number, lines)] = list(checker.wake_calls(body))
    failures, _, _ = checker.check(lines)
    assert any("never reached the call" in reason for reason in failures)


def test_only_wake_calls_are_checked(tmp_path):
    log = tmp_path / "voice-console.log"
    log.write_text(ACTION_BUTTON + GOOD_BACKGROUND)
    assert [number for number, _ in checker.wake_calls(log.read_text())] == [2]
    assert checker.main([str(log)]) == 0
    log.write_text(ACTION_BUTTON + BROKEN_FOREGROUND)
    assert checker.main([str(log)]) == 1
