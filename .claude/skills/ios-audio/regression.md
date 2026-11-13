# Audio regression checklist

Run this after any change to the microphone, the listener, the audio session, background
behaviour, calls or anything that starts at launch (Live Activity, warm-ups, prebuilds).
`interactions.md` explains what each behaviour is and why; this file is the list to tick.

Record each run in `docs/verification.md` (SHA, phone, iOS) and update `interactions.md`
when a result changes. A scenario marked **you** needs a physical action on the phone; the
rest can be driven from the Mac with launch options.

## Before you start

- Install the build, then clear the logs (`copy to` an empty file for
  `Documents/voice-console.log`; `latency.jsonl` can stay, each session is a new line).
- Open Wake On by tapping its icon, not with `devicectl` (a Mac launch prepares the call
  audio differently, suspected on 2026-11-07).
- Settings at their defaults unless the scenario says otherwise (table below).
- After the run, pull both logs and summarise listener sessions with the script in
  `interactions.md`.

## Settings that change audio behaviour

| Setting (Simple or Advanced tab) | Key | Default | What it changes |
|---|---|---|---|
| Listen for "Hey Lobby" | (listener on/off) | off at launch | Starts the shared listener session |
| Start a conversation on "Hey Lobby" | `listener.talkOnWake` | off | Wake starts a call inside the listener's session |
| Keep listening while other audio plays | `listener.shareAudio` | on | `.mixWithOthers`; off = exclusive, media interrupts it |
| Full sound for other apps | `listener.fullSoundForOthers` | on | `.default` mode instead of `.measurement` |
| Resume after calls, Siri and alarms | `listener.autoResume` | on | Restart after interruptions and route changes |
| Use iPhone microphone with headphones | `listener.builtInMicrophone` | on | A2DP + built-in mic instead of HFP |
| Keep screen on while charging | `screen.awakeWhileCharging` | on | Idle timer off while charging and open |
| Visualizer | `voiceVisualizerStyle` | Sky orb | Also drawn in the Live Activity |
| End after silence | `voice.idleSeconds` | 10 s | Idle check-in timing |

Debug-only switches (Advanced tab › Audio experiments, debug builds), for isolating suspects.
They apply from the next launch, so force-quit Wake On and open it by tapping its icon:
`debug.noLiveActivity` (no Dynamic Island orb), `debug.noLaunchPrebuild` (no call audio
prepared at launch).

## Scenarios

Each line: what to do → what the logs must show.

### L. Listener staying alive

- **L1 Background, silence (you).** Start listening, go to the home screen, wait 60 s.
  → No `stop_requested` in the trace; Live Activity shows listening.
- **L2 Locked, silence (you).** Same with the phone locked for 5 min.
  → No stop; `session_activation_begin settings=share=true … mode=AVAudioSessionModeDefault`.
- **L3 Long run (you, occasional).** Locked and unplugged for an hour or more.
  → No stop; battery screen ~9 mW app power.

### M. Other apps' audio

- **M1 Music started after listening (you).** Start listening, switch to Spotify, play a song,
  say "Hey Lobby" over it. → No interruption; wake detected; Spotify sounds normal.
- **M2 Listening started over music (you).** Play Spotify first, then start listening in
  Wake On, go home, say "Hey Lobby". → Same as M1.
- **M3 Video (you).** Same as M1 with a YouTube video.
- **M4 Sharing off (you).** Turn off "Keep listening while other audio plays", play Spotify.
  → Interruption; "Listening paused" notice at once; pausing Spotify gives
  `shouldResume=false`; tapping the notice resumes.

### I. Interruptions

- **I1 Siri (you).** While listening in the background, use Siri. → Stop with
  `interruption`; `interruption_ended`; `auto_resume_succeeded` without opening the app.
- **I2 Clock timer (you).** 10 s timer, let it ring, stop it. → Same as I1.
- **I3 Phone or FaceTime call (you, occasional).** → Same as I1 after the call.

### R. Routes

- **R1 AirPods connect while listening (you).** → `route_change reason=1`, then auto-resume
  on the built-in mic; music in AirPods stays high quality.
- **R2 AirPods disconnect (you).** → Auto-resume; no stuck "paused".

### C. Calls

- **C1 Action Button call, app closed (you).** → `session_configure … mode=VoiceChat`, voice
  processing on at `session.started`, reply heard on the speaker. **Never regress this.**
- **C2 Action Button call with the listener on (you).** → Listener stops `voice_call`, call
  works as C1, listener running again after the call.
- **C3 Hey Lobby call, app on screen (you).** "Hey Lobby, what's the time" in one breath.
  → `session_kept`, `audio_waits_for_pause`, full request in the transcript;
  `check-wake-handover.py` exits 0.
- **C4 Hey Lobby call, phone locked (you).** Same as C3, locked. → `outputs=Speaker`, no
  reason 3/8 route changes mid-call, listener back after the call.
- **C5 Hey Lobby call over music (you).** Same as C4 with Spotify playing. → Same; music
  resumes after the call.
- **C6 Goodbye and idle hang-up (you).** Say "thanks, bye"; another call, stay silent.
  → `goodbye` hang-up ~2 s after Lobby's bye; idle check-in then hang-up.
- **C7 Test calls from the Mac.** `--talk <probe>` (spotify, pause, map, browser).
  → Each probe answered; see the probe list in `VoiceSessionController.Probe`.

### A. App lifecycle

- **A1 Launch by tap, then start listening (you).** → No `stop_requested` in the first 30 s
  after going to the background (the open regression; see `interactions.md`).
- **A2 Reinstall while listening.** → Listener ends with the app; next tap launch starts
  clean.
- **A3 Spotify opened by Lobby (you).** "Hey Lobby, play Come Sail Away". → Listener running
  again before Spotify opens (`spotify_after_listener listening=true`).

### Automated (always)

- Wake detection over music, offline: `.venv/bin/python -I native/ios/scripts/wake-over-music.py
  <work dir>` after any change to the wake model, keywords file or detector settings. Compare
  with the table in `interactions.md` (2026-11-13: 22–23 of 32 at +10 dB, 13–14 at 0 dB).

- Wake On unit tests (`xcodebuild … test`), including `WakeHandoverTests`.
- Chat Lab UI tests if the chat or captures changed.

## Minimum set by kind of change

| Change | Run at least |
|---|---|
| Listener session, settings, resume code | L1, M1, M4, I1, A1, C2 |
| Call audio, voice processing, handover | C1, C2, C3, C4, C5 |
| Anything at launch or on background/foreground | A1, L1, C1, C4 |
| Routes, Bluetooth | R1, R2, M1 |
| Before calling the listener "done" | All of L, M, I, C; R if headphones are handy |
