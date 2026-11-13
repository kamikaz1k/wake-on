"""How well the phone's wake detector hears "Hey Lobby" over music.

Usage: .venv/bin/python -I native/ios/scripts/wake-over-music.py <work dir>
Music comes from GarageBand's Apple Loops on this Mac (converted into <work dir>/music);
results go to <work dir>/wake_over_music.json. Takes about a minute.

Mixes each saved positive recording with a music bed at several voice-to-music levels
(SNR, dB: speech loudness while speaking vs. music loudness) and runs sherpa-onnx with the
phone's settings, plus more sensitive thresholds. Also counts false wakes on music alone.
"""
import json, subprocess, sys, wave
from pathlib import Path
import numpy as np
import sherpa_onnx

REPO = Path("/Users/kaiser/workspace/wake-on")
RES = REPO / "native/ios/Resources"
SP = Path(sys.argv[1])
RATE = 16000

def read(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

def rms(x): return float(np.sqrt(np.mean(x * x)) + 1e-12)

def active_rms(x):
    """RMS over 20 ms frames within 30 dB of the loudest frame (the speech itself)."""
    f = x[: len(x) // 320 * 320].reshape(-1, 320)
    r = np.sqrt((f * f).mean(axis=1)) + 1e-12
    keep = r > r.max() * 10 ** (-30 / 20)
    return float(np.sqrt((f[keep] ** 2).mean()))

LOOPS = Path("/Library/Audio/Apple Loops/Apple")
STEMS = {
    "funk": ["09 Disco Funk/Electric Funk Beat", "09 Disco Funk/Disco Delight Slap Bass",
             "09 Disco Funk/Disco Delight Electric Piano 02", "09 Disco Funk/Boogie Right Vox Synth",
             "09 Disco Funk/Boogie Right Funk Guitar 01"],
    "rnb": ["04 Modern RnB/Down Low Beat 01", "04 Modern RnB/Electric Daisy Bass 01",
            "04 Modern RnB/Breathless Piano", "07 Chillwave/Before Dawn Vox",
            "04 Modern RnB/Driving Home Synth Pad"],
}

def convert_loops():
    (SP / "music").mkdir(parents=True, exist_ok=True)
    for prefix, names in STEMS.items():
        for i, name in enumerate(names):
            out = SP / "music" / f"{prefix}-{i}.wav"
            if not out.exists():
                subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                str(LOOPS / f"{name}.caf"), str(out)], check=True)

def bed(prefix, seconds=90):
    stems = []
    for p in sorted((SP / "music").glob(f"{prefix}-*.wav")):
        s = read(p)
        s = np.tile(s, int(np.ceil(seconds * RATE / len(s))))[: seconds * RATE]
        stems.append(s / rms(s))
    mix = np.sum(stems, axis=0)
    return mix / rms(mix) * 0.1

def spotter(threshold, score):
    return sherpa_onnx.KeywordSpotter(
        tokens=str(RES / "tokens.txt"), encoder=str(RES / "encoder.onnx"),
        decoder=str(RES / "decoder.onnx"), joiner=str(RES / "joiner.onnx"),
        num_threads=1, max_active_paths=16, keywords_file=str(RES / "hey-lobby.txt"),
        keywords_score=score, keywords_threshold=threshold, num_trailing_blanks=0, provider="cpu")

def detections(kws, audio):
    s = kws.create_stream()
    hits = 0
    for i in range(0, len(audio), 1600):  # 100 ms chunks, as the phone's listener does
        s.accept_waveform(RATE, audio[i : i + 1600])
        while kws.is_ready(s):
            kws.decode_stream(s)
            if kws.get_result(s):
                hits += 1
                kws.reset_stream(s)
    s.accept_waveform(RATE, np.zeros(RATE // 2, dtype=np.float32))
    while kws.is_ready(s):
        kws.decode_stream(s)
        if kws.get_result(s):
            hits += 1
            kws.reset_stream(s)
    return hits

convert_loops()
manifest = [json.loads(l) for l in open(REPO / "recordings/manifest.jsonl")]
clips = [(m["path"], m["environment"], read(REPO / "recordings" / m["path"])) for m in manifest]
beds = {"funk": bed("funk"), "rnb": bed("rnb")}
snrs = [None, 20, 10, 5, 0, -5, -10]
configs = [(0.1, 2.0), (0.05, 2.0), (0.02, 2.0), (0.05, 3.0)]
rng = np.random.default_rng(7)
pad = np.zeros(RATE, dtype=np.float32)

results = {}
for threshold, score in configs:
    kws = spotter(threshold, score)
    key = f"threshold={threshold} score={score}"
    table = {}
    for name, music in beds.items():
        for snr in snrs:
            hit = 0
            for path, env, voice in clips:
                v = np.concatenate([pad, voice, pad])
                if snr is None:
                    mixed = v
                else:
                    start = rng.integers(0, len(music) - len(v))
                    m = music[start : start + len(v)]
                    m = m * (active_rms(voice) / rms(m)) / 10 ** (snr / 20)
                    mixed = np.clip(v + m, -1, 1)
                hit += detections(kws, mixed) > 0
            table[f"{name} snr={'clean' if snr is None else snr}"] = hit
    false = {name: detections(kws, music) for name, music in beds.items()}
    results[key] = {"detected_of_32": table, "false_wakes_per_90s_music": false}
    print(key, json.dumps(results[key]), flush=True)

json.dump(results, open(SP / "wake_over_music.json", "w"), indent=1)
