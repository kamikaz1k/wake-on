#!/usr/bin/env python3
"""Remake the visualizer gallery's sample conversation (Resources/VisualizerSamples/viz-*.wav).

    .venv/bin/python -I native/ios/scripts/make-visualizer-samples.py

Speaks each line with OpenAI gpt-4o-mini-tts (Pixie in Marin, the app's default call voice; the
user in Cedar), then trims the silence and normalizes to 24 kHz mono 16-bit. The OpenAI key is
read from server/.env (OPENAI_PROJECT_API_KEY) and never printed. The lines must match
SampleConversationPlayer.lines, which shows them as captions. Costs well under a cent.
"""
import io, json, urllib.request, wave
from pathlib import Path
import numpy as np

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "native/ios/Resources/VisualizerSamples"
RATE = 24000
USER = ("cedar", "Speak like a real person talking to a voice assistant on their phone: casual, relaxed, "
        "slightly hurried, natural pitch movement, not a narrator.")
PIXIE = ("marin", "You are a friendly voice assistant on a phone call. Warm, conversational, natural pace "
         "and small pauses, not a newsreader.")
LINES = {
    "u1": (USER, "Hey, can you check if my flight to Lisbon is still on time?"),
    "a1": (PIXIE, "Sure. Your flight TP 238 leaves at 6:40 this evening, and it's currently on time. "
                  "Boarding starts at 6:05, from gate B12."),
    "u2": (USER, "Great. And what's the weather like when I land?"),
    "a2": (PIXIE, "Lisbon will be around 19 degrees and clear when you land, with a light breeze off the river. "
                  "You probably won't need a jacket, but maybe bring something light for later in the evening, "
                  "because it can get—"),
    "u3": (USER, "Sorry, quick one, is that Celsius?"),
    "a3": (PIXIE, "Yes, 19 Celsius. That's about 66 Fahrenheit."),
}

def api_key():
    for line in (REPO / "server/.env").read_text().splitlines():
        if line.startswith("OPENAI_PROJECT_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("OPENAI_PROJECT_API_KEY missing from server/.env")

def speak(key, voice, style, text):
    body = json.dumps({"model": "gpt-4o-mini-tts", "voice": voice, "input": text,
                       "instructions": style, "response_format": "pcm"}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/audio/speech", body,
                                 {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:  # pcm: raw 24 kHz mono int16
        return np.frombuffer(r.read(), dtype=np.int16).astype(np.float32) / 32768

def tidy(x):
    """Trim to 40 ms around the speech (20 ms frames within 30 dB of the loudest), fade, peak 0.8."""
    f = np.sqrt((x[: len(x) // 480 * 480].reshape(-1, 480) ** 2).mean(1))
    on = np.where(f > f.max() * 0.03)[0]
    y = x[max(0, (on[0] - 2) * 480): min(len(x), (on[-1] + 3) * 480)].copy()
    fade = min(240, len(y))
    y[:fade] *= np.linspace(0, 1, fade); y[-fade:] *= np.linspace(1, 0, fade)
    return y / np.abs(y).max() * 0.8

key = api_key()
for name, ((voice, style), text) in LINES.items():
    y = tidy(speak(key, voice, style, text))
    with wave.open(str(OUT / f"viz-{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes((y * 32767).astype(np.int16).tobytes())
    print(f"viz-{name}.wav {len(y) / RATE:.2f}s")
