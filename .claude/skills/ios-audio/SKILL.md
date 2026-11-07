---
name: ios-audio
description: Wake On iOS audio playbook - AVAudioSession categories/modes/options, microphone and speaker routing, echo cancellation (voice processing), background limits ('!int'), the Hey Lobby listener to call handover, call ending, Bluetooth/AirPods (A2DP vs HFP), interruptions and auto-resume, and how to read the phone's voice logs. Use before changing HotAudioDevice, WakeController, ListenerSettings, VoiceSessionController or anything touching the mic, speaker, audio session, calls or headphones, and when debugging audio bugs from device logs.
---

# iOS audio in Wake On

Hard-won facts from building the "Hey Lobby" listener and GPT-Live calls on an iPhone 17 Pro.
Each line was learned from a device log or a failed attempt. Check the code still matches
before relying on a detail; update this file when you learn something new.

Key files (in `native/ios/WakeOn/`): `HotAudioDevice.swift` (call engine, voice processing,
bridge, backlog), `WakeController.swift` (listener, detection, handover),
`ListenerSettings.swift` (listener session config), `VoiceSessionController.swift` (call
lifecycle, goodbye/idle hang-up), `VoiceActivity.swift` (turn detection),
`ListeningActivityController.swift` (Live Activity). Background doc:
`docs/ios-voice-latency.md` (every latency experiment and result).

## Two session configurations

| | Listener ("Hey Lobby") | Call (foreground start) |
|---|---|---|
| Category | `.playAndRecord` | `.playAndRecord` |
| Mode | `.default` when sharing + full sound, else `.measurement` | `.voiceChat` |
| Options | `.defaultToSpeaker`, `.mixWithOthers` (sharing), `.allowBluetoothA2DP` (iPhone mic) or `.allowBluetoothHFP` | `.defaultToSpeaker`, `.allowBluetoothHFP` |
| Log line | `session_activation_*` | `session_configure ... mode=VoiceChat` |

- `.measurement` turns off system audio processing for the whole route, so Spotify/YouTube
  sound flat while the listener runs. `.default` fixes that and the wake word still works
  over music. Default listener setting: share + full sound → `.default`.
- `.voiceChat` is where iOS's echo cancellation is tuned for speakerphone. Calls in other
  modes still get voice processing but leak more of Lobby's own voice into the mic.
- Re-activating an already-active session costs ~90–105 ms even when nothing changes. Skip it.
- The listener sets its own category/mode again whenever it restarts (after a call too).

## Background limits (the big ones)

- **iOS refuses to start the microphone from the background.** Start it in the foreground
  (or at will-enter-foreground), or keep an already-running session alive.
- **`'!int'` (OSStatus 560557684, "cannot interrupt others")**: from the background iOS
  refuses any non-mixable session change: `setActive` on an exclusive session, a category
  change, and (verified 2026-11-07) **even a mode-only change to `.voiceChat` with the
  mixable options kept**.
- **A failed `setCategory` still changes the route.** The mode-only attempt above threw
  `'!int'` but posted route changes reason 8 + 3, and Lobby played through the **earpiece**
  ("audio too low"). Never try-and-ignore session changes from the background; log
  `currentRoute.outputs` before and after anything that touches the session.
- What does work in the background: keep the listener's active shared session and start a
  voice-processing `AVAudioEngine` inside it (background wake calls do this,
  `backgroundStart = true`, log `session_kept ... outputs=Speaker`). If voice processing is
  refused there, the engine falls back to a plain mic (`voice_processing_start_failed`,
  `engine_running voiceProcessing=false`).
- A background app cannot open URLs or other apps, and cannot start a Live Activity
  (`live_activity_start_skipped background`). Exceptions: user taps a notification, Live
  Activity, or Control, or an App Intent continues in the foreground.
- Restarting an exclusive session in the background also fails with `'!int'`, so after an
  interruption the app posts "Listening paused · tap to resume" at once.

## Echo cancellation (voice processing)

- Enabling voice processing (`setVoiceProcessingEnabled`) takes ~120–180 ms; the built
  engine is kept between calls to skip it.
- Voice processing is **bypassed while only buffering** (nothing is playing, so no echo) and
  switched on at `session.started` for Action Button calls, or at Lobby's first reply for wake
  calls (`voice_processing_on ms=…`).
- Starting echo cancellation **silences the iPhone mic for ~300 ms**. No handover can
  recover that, so wake calls play a short ready chime when the call mic records.
- Background wake calls stay in the listener's `.default` mode (see `'!int'`), so echo
  cancellation is weaker and Lobby can interrupt itself on the speaker. Open problem as of
  2026-11-07. Candidate fixes: gate the mic while Lobby is talking unless the user is much
  louder, play quieter in background calls, or run the listener itself in `.voiceChat`
  (affects other apps' audio and battery).
- **Never trust mic level alone** to mean the user spoke: echo of Lobby used to cancel
  hang-ups and answer check-ins. Only transcribed words count.
- Simulator: the Mac's speakers feed its mic with no echo cancellation, causing fake turns.
  Measure turns on the device only.

## Hey Lobby → call handover

**Regression guard (this broke several times):** run the `WakeHandoverTests` unit tests, then
test "Hey Lobby, <request>" on the phone **with the app on screen and in the background**, pull
the log and run `native/ios/scripts/check-wake-handover.py <log>` (exit 1 = broken).

- **Every wake-word call keeps the listener's session** (`keepsListenerSession`), on screen
  too. With the app on screen it used to switch to voice chat, which took ~1 s
  (`session_configure ... sessionMs≈974`). The listener recorded silence meanwhile
  (`tailDb=-120`), so "come sail away with me" arrived as "away with me". Foreground
  wake calls now get the same weaker echo cancellation as background ones.
- **Wake calls turn echo cancellation on only when Lobby starts replying**
  (`defersVoiceProcessing`, first `session.output_transcript.delta`, or a 10 s limit). Turning it
  on at `session.started` (~0.7 s after the wake) silenced the mic ~0.3 s mid-sentence: "can you
  play come sail away with me" arrived as "can you away with me". The handover log looked fine;
  only the transcript showed it. Log: `voice_processing_deferred` then `voice_processing_after reply`.
- **Starting the call's audio engine mutes the iPhone's mic ~0.5 s** (the listener's audio and
  the call's both go to exact digital zeros, seen in `Documents/backlog-*.wav`). Mid-sentence that
  ate "come" from "play come sail away". So wake calls **start the engine at the user's first
  pause** (`startsAudioAtPause`, `PauseDetector`: 0.6 s at 15 dB under the wake phrase's level or
  below -50 dB; 8 s limit). Until then `mayArm = false` keeps WebRTC from starting it, and the
  listener stages everything (bridge 10 s, backlog 20 s). Log: `audio_waits_for_pause` then
  `audio_start_after_pause reason=pause afterMs=…`. Cost: OpenAI hears the request only after
  the pause.
- **To find a mid-sentence gap, pull the call audio:** debug builds save
  `Documents/backlog-<time>.wav` (48 kHz mono, what was sent). Print 20 ms levels; a run of
  exact zeros is a muted mic, not a quiet user.
- **Read the transcript, not just the handover numbers:** a gap in the middle of a sentence means
  the mic went silent mid-call (echo cancellation, session or route change), not a late bridge.

- The keyword spotter (sherpa-onnx, `WakeDetector`) fires **~0.25–0.36 s after the phrase
  ends** (measured on `recordings/positive`). The bridge therefore starts
  `WakeController.bridgeLookback` (0.4 s) before the detection point, using kept chunks
  (`recentPCM`). Before that fix, "Hey Lobby, what's going on" lost "what's".
- Sherpa keyword timestamps are only meaningful before the first stream reset; after
  `reset()` they drift (seconds off). Don't use them to cut audio.
- In Python, each `KeywordSpotter.get_result/tokens/timestamps` call consumes the result;
  read all fields from one `keyword_spotter.get_result(s)` call.
- The listener keeps recording until the call mic's first frame; its audio is cut at that
  host time and placed before the call's backlog (`wake bridge merged bridgeMs=… seamGapMs≈0`).
  `tailDb` very low (-100 or less) means the listener was being fed silence.
- Route changes during handover are ignored (`wake_handover_route_change_ignored`); stopping
  early would drop the partly recorded chunk.
- The backlog is released at `session.started` and sent at 4× real time.

## Call ending

- Goodbye: once Lobby's latest line ends with "bye", the app hangs up after 2 s of silence.
  **Known bug:** people talking nearby keep it open (and it keeps transcribing them). It
  should hang up shortly after Lobby's farewell regardless of room noise.
- Idle check-in: after the configured silence Lobby asks "Anything else?", and the call ends
  2 s after that with no answer.
- A second Action Button press hangs up.

## Bluetooth, AirPods, routes

- `.allowBluetoothA2DP` keeps headphones in high-quality playback (output only). Only
  `.allowBluetoothHFP` lets headphones provide the mic, and it drops them to call quality.
  The listener defaults to the iPhone's built-in mic (`setPreferredInput(builtInMic)`) with A2DP.
- Route change reasons: 1 new device, 2 old device gone, 3 category change, 4 override,
  8 route configuration change. Connecting AirPods posts reason 1, then overrides (4). The
  listener stops and auto-resumes (`wake_listener_auto_resume trigger=after_change/retry_n`).
- Options value 41 = `mixWithOthers | defaultToSpeaker | allowBluetoothA2DP`.
- `AVAudioEngineConfigurationChange` → the call engine restarts (`restartLocked`). Never
  rebuild or re-arm on WebRTC's thread: it stalled the answer ~1 s.

## Interruptions and resume

- Phone calls, Siri, alarms and other apps' exclusive audio interrupt the listener
  (`interruption type=1`). On `interruption_ended shouldResume=true` it resumes; route
  changes and media-service resets resume "soon" with background retries.
- A voice call cancels a pending resume, hands the session over without releasing it
  (listener stop 173 → 18 ms), and restarts the listener when the call ends. Background
  calls keep the session active after the call so the listener can take it back.

## Debugging from the phone

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl device copy from --device 5976CF6D-0FD6-5A57-9711-AA29F94404E7 \
  --domain-type appDataContainer --domain-identifier dev.wakeon.ios \
  --source Documents/voice-console.log --destination <scratchpad>/voice-console.log
```

- Also `Documents/latency.jsonl` (traces). `scripts/summarize-voice-log.py` and
  `scripts/summarize-latency.py` summarise them.
- Needs `dangerouslyDisableSandbox`. Over Wi-Fi it often fails (CoreDevice reachability, see
  `native/ios/scripts/device-link-check.py`); plug in the cable if `devicectl` errors.
- Copy the log out before clearing it; clear it after installing a test build so the next
  test is easy to read.
- Useful greps: `start trigger=`, `session_kept|session_configure` (mode, options, outputs),
  `voice_processing`, `engine_running`, `route_change`, `wake bridge merged`, `transcript`,
  `goodbye`, `ended reason=`, `wake_listener_`.
- `level mic=… reply=…` lines are sampled sparsely; don't use them alone to prove echo.

## Numbers from device logs (Nov 2026, iPhone 17 Pro)

- Background wake call: trigger → call mic live 347–419 ms; trigger → audio reaching OpenAI
  560–1,370 ms; first engine start after a fresh install ~600 ms (later ~35–100 ms).
- Bridge length 380–510 ms before the lookback fix, ~1,020 ms after (0.3 s lookback plus a
  slower first engine start).
- Foreground fast-start calls: `.voiceChat`, voice processing on in ~30 ms at `session.started`.
- Before 2026-11-07, every background call logged `session_kept mode=Default options=41`
  and voice processing on, so the plain-mic fallback was not the cause of self-interruption.
- In one background call Lobby's lines arrived split ("One moment. What city" / "or area",
  "You're" / "welcome. Bye.") with the mic active during playback, which fits echo.
- The same call never hung up after "thanks, bye": nearby conversation kept "speaking=yes"
  and was transcribed for minutes.
- AirPods connecting mid-listen: `route_change reason=1(new_device) inputs=<BT id>`, then
  four `reason=4(override)` retries before the listener resumed on the built-in mic.
- Listener measured ~9 mW, 0.24% CPU while locked; under 1% battery in 73 minutes.

## Before shipping an audio change

- Don't regress the Action Button flow (foreground `.voiceChat` calls).
- Test on the device: a locked-phone "Hey Lobby" call, an Action Button call, music playing
  alongside, and AirPods connected. Check the log shows `outputs=Speaker` (or the headphones)
  and no unexpected reason 3/8 route changes mid-call.
