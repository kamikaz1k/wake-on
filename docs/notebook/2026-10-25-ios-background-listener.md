# iOS background listener: battery and recovering from other audio

- **Date:** 2026-10-25
- **Status:** shared listening with full sound is the default; calls and alarms resuming by
  themselves are not yet tested
- **Question:** what does background "Hey Lobby" listening cost in battery, and can it
  survive other apps using audio?

## Battery

`BatteryMonitor` records each listening session and voice call. Every 30 s, and at every
foreground/background change, it samples the kernel's per-process energy estimate
(`task_power_info_v2.task_energy`, nanojoules), CPU time, CPU wake-ups, battery level and
charging state, Low Power Mode and thermal state. Sessions are stored on the phone and
shown on the **Battery use** screen, together with Apple's daily MetricKit reports.

Measured on an iPhone 17 Pro with the screen locked, unplugged:

| Session | Duration | App power | CPU | Wake-ups | Battery |
|---|---|---|---|---|---|
| 1 | 15 min | 9.8 mW | 0.24 % | 27/s | 100 % → 100 % (unusable) |
| 2 | 73 min | 8.7 mW | 0.24 % | 29/s | 95 % → 95 % |

Wake On's own process costs ~9 mW, about 0.05 % of the battery per hour. The phone as a
whole lost less than 1 % in 73 minutes; iOS reports the level in 1 % steps, so a
multi-hour run is needed for a real rate. The app figure excludes the microphone hardware
and iOS's audio service, which belong to the system.

## Why listening stopped

Both early sessions ended without an explicit stop. Recording the stop reason showed an
AVAudioSession interruption (`reason=0`, default). The phone was not killed: iOS left no
crash, memory or CPU-limit report.

## Other apps' audio

| Listener mode | Spotify / YouTube starts | When it stops | Result |
|---|---|---|---|
| Exclusive (sharing off) | Interrupts the listener | Ends with `shouldResume=false`; background activation fails with `'!int'` (cannot interrupt others) | Resumes only when the app is opened (or the notification is tapped) |
| Shared, measurement mode | Plays alongside | — | Keeps listening; other apps' speaker sound is flat and quiet |
| **Shared, default mode** | Plays alongside | — | **Keeps listening; speaker sounds identical to listening off; "Hey Lobby" detected over music** |

Findings:

- Media apps play in exclusive mode and never grant `shouldResume` when paused or left.
  iOS does not let a background app activate an exclusive session, so retries fail
  (`otherAudio=false` and `'!int'` on every attempt) until the app is in front.
- The "flat" speaker came from **measurement mode**, not from sharing or recording as
  such. In default mode the shared listener left Spotify's sound unchanged.
- The paused notification now posts when the interruption begins (it used to wait for
  the failed resume, ~7 s later in the YouTube test).
- Handing the microphone to a voice call no longer releases the session first: the
  listener's stop takes 18 ms instead of 173 ms, and the call's microphone goes live at
  ~365 ms instead of 415 ms with the listener running.

Options considered for recovering after media apps:

- **Default mode while sharing:** adopted; it removes most of the need to recover.
- **Live Activity with an audio-recording intent:** a Lock Screen resume button. Not
  pursued; it does not help while the phone is in use.
- **Shortcuts automation on leaving a media app:** rejected; too much setup.
- **Step aside while media plays:** poll `isOtherAudioPlaying` and keep the app awake
  with silent playback. Not built; App Review rejects keep-alive audio.

## Open

- Calls and alarms are expected to end with `shouldResume=true`; test with a Clock timer.
- Wake-word accuracy in default mode over music: one detection so far.
- A multi-hour unplugged session for a real battery rate.
