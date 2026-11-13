# How the Hey Lobby listener reacts to other audio and app events

One row per situation: what happens, what the app does, and how sure we are. Read this
before changing interruption, resume or session code, and **add a row (or update one) after
every device test** with the date and the evidence. Sources: device logs
(`Documents/voice-console.log`, `Documents/latency.jsonl` traces), the notebook entry
`docs/notebook/2026-10-25-ios-background-listener.md`, `native/ios/README.md`.

The listener's stop reasons are in the latency trace (`stop_requested reason=…`, one trace
per listening session, with `session_activation_begin settings=…` and lifecycle marks), not
in the voice log. A quick summary of every session's settings, background time, stop reason
and wake times: see "Summarise listener sessions" below.

## Media apps (Spotify, YouTube)

| Listener mode | Situation | What happens | Status |
|---|---|---|---|
| Exclusive (sharing off) | Media starts | Interrupts the listener (`interruption reason=0`) | Verified 2026-10-26 (YouTube, Spotify) |
| Exclusive | Media pauses or the user leaves it | `interruption_ended shouldResume=false`; every background restart fails with `'!int'`; resumes only when the app is opened or the notice is tapped | Verified 2026-10-26 (YouTube, Spotify) |
| Shared, measurement mode | Media plays | Plays alongside; listener keeps going; other apps sound flat and quiet | Verified 2026-10-26 |
| Shared, default mode (**the default**) | Media starts with the listener running in the background | Plays alongside at full sound; listener keeps going; "Hey Lobby" detected over music (trace 2026-10-26T01:04Z: background at 4 s, no stop, wake at 19 s) | Verified 2026-10-26, **once**. Contradicted 2026-11-13, see below |
| Shared, default mode | Same as above, 2026-11-13 08:54 | Interrupted 0.9 s after going to the background (`interruption reason=0`); stayed off while music played; `interruption_ended shouldResume=true` ~15 s later, restarted from the background and succeeded (`auto_resume_succeeded`, within the 30 s background task) | **Open regression** |

## The early-background interruption (open, since 2026-10-27)

Interrupted about 1 s after the app goes to the background, in shared default mode:

- 2026-10-27T01:59Z: background at 3 s, interrupted at 4 s. **No music**: this was the first
  test of the Dynamic Island orb (Live Activity, `f0d8320`, built 01:57).
- 2026-11-07T16:33Z: stopped at the moment of going to the background with
  `route_change reason=3 (category_change)`, then `'!pla'` on restart. Blamed then on a
  `devicectl` launch, not proven.
- 2026-11-13T13:54Z: background at 14.4 s, interrupted at 15.3 s, with Spotify starting.

2026-11-13T14:27Z (40dc21d), **no music**, orb on and launch prebuild on: three trips to
the background (20 s, 10 s, 19 s), no interruption. So going to the background alone does
not trigger it; the remaining suspect is another app starting playback. (The debug switches
were not in effect: no `experiment` lines, the app wasn't relaunched.) Two more interruptions
the same morning came 108 s and ~5 min after going to the background, both ending
`shouldResume=true` ~33–47 s later, cause unknown (likely the user's own music).

The one clean pass (2026-10-26T01:04Z) predates the Live Activity. Suspects, untested:

1. **The Live Activity** (`ListeningActivityController`), new between the pass and the first
   failure.
2. **Our own call audio prepared at launch:** `AppDelegate` runs `HotAudioDevice.prebuildAsync`
   whenever `applicationState == .background` at launch, which is every launch of a
   scene-based app. It sets `.playAndRecord/.voiceChat` (not mixable) and builds a voice
   processing engine, before the listener sets its shared session. Present since 2026-10-25,
   so also during the pass, but the warm-up and call engine changed on 2026-11-07.

Next step: a controlled test without music, one change at a time. Start listening in the
app, go to the home screen, wait 20 s, read the trace. Then repeat with the Live Activity
off, then with the launch prebuild skipped. Then repeat the passing case (music started
from Spotify while listening in the background).

## Calls, Siri, alarms

| Situation | What happens | Status |
|---|---|---|
| Phone call, alarm, timer, Siri | Interrupt even shared sessions; usually end with `shouldResume=true`; listener restarts on `interruption_ended` | Expected from Apple's docs; **not tested on the device** |
| Lobby call (Action Button or Hey Lobby) | Listener hands the session over (`voice_call`), call restarts it when it ends | Verified many times |

## Restarting from the background

| Session | Result | Status |
|---|---|---|
| Exclusive | Refused: `'!int'` (and `'!pla'` seen once) | Verified 2026-10-26, 2026-11-07 |
| Shared | Worked within the 30 s background task after `interruption_ended` | Verified once, 2026-11-13 |
| Shared, while other audio is still playing | Not tried. The retry loop deliberately waits for `isOtherAudioPlaying == false` | Unknown |
| Changing mode to `.voiceChat` from the background | Refused with `'!int'`, **and still moved output to the earpiece** | Verified 2026-11-07 |

## Routes

| Situation | What happens | Status |
|---|---|---|
| AirPods connect while listening | `route_change reason=1`, then several `reason=4`; listener stops and auto-resumes on the built-in mic | Verified 2026-10-27 |
| A Lobby call's mic starting during the handover | Route change (override), ignored during handover | Verified 2026-10-26 |

## Summarise listener sessions

```sh
python3 - latency.jsonl <<'EOF'
import json,sys
for line in open(sys.argv[1]):
    try: d=json.loads(line)
    except: continue
    ev=d.get('events',[]); names=[e['name'] for e in ev]
    if 'session_activation_begin' not in names: continue
    sett=[e.get('settings') for e in ev if e['name']=='session_activation_begin'][0] or ''
    bg=[round(e['elapsedMs']/1000) for e in ev if e.get('notification','').endswith('DidEnterBackgroundNotification')]
    stops=[(round(e['elapsedMs']/1000),e.get('reason')) for e in ev if e['name']=='stop_requested']
    wakes=[round(e['elapsedMs']/1000) for e in ev if 'wake' in e['name'] or 'detect' in e['name']]
    print(d['startedAt'], d.get('outcome'), 'bg@',bg[:3], 'stop',stops, 'wake@',wakes[:5], sett[-30:])
EOF
```
