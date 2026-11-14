---
name: ios-device-dev
description: Wake On iPhone build/install/debug playbook - building and installing on the physical phone with xcodebuild + devicectl, free Personal Team signing and 7-day profile expiry, wireless (Wi-Fi) install failures and the device-link-check diagnostics, pulling app logs, and iOS platform limits learned while scoping features (Live Activities, App Intents vs Controls, opening URLs, Spotify, background launch). Use before installing a build on the phone, when an install or devicectl command fails, when the app stops launching, or when scoping a new iOS feature.
---

# Building, installing and debugging Wake On on the iPhone

Learned the hard way in Oct–Nov 2026. Check facts still hold before relying on them.

## Build and install (phone)

**Use the deploy script** (needs `dangerouslyDisableSandbox`):
`python3 -I native/ios/scripts/deploy-phone.py [--check] [--launch] [--no-install]`.
It reports profile expiry, builds, renews signing if the build fails on signing, and installs.
Renewal order: an App Store Connect API key in `~/.appstoreconnect/wakeon.env` (Apple's
headless method, the CI standard; none set up yet), then Xcode's saved account
(`-allowProvisioningUpdates`), then the running Xcode app over AppleScript (open + build; Xcode
renews with the account it holds). Tested 2026-11-14: normal deploy and the Xcode-app path both
ran with no prompts.

Why command-line builds said "No Accounts" (2026-11-14): Xcode's saved account list
(`defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`) is **empty**, while
the Xcode app (running since 2026-07-12) still holds the account in memory. If Xcode quits, the
app path stops working too, until the user signs in again in Xcode › Settings › Accounts (or an
App Store Connect key is configured). Profiles now last 365 days (TimeToLive 365), which
suggests the team is in the paid program now; the old Personal Team profiles lasted 7.

Manual commands:

```sh
cd native/ios
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select points at CLT
xcodebuild -project WakeOn.xcodeproj -scheme WakeOn -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=JDR6VAV2RA build
xcrun devicectl device install app --device 5976CF6D-0FD6-5A57-9711-AA29F94404E7 \
  build-device/Build/Products/Debug-iphoneos/WakeOn.app
```

- `devicectl` and network tools need `dangerouslyDisableSandbox`.
- Simulator tests: `xcodebuild ... -destination 'platform=iOS Simulator,id=<udid>'
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` (29 tests as of Nov 2026).
- Device: CoreDevice id `5976CF6D-0FD6-5A57-9711-AA29F94404E7`, bundle `dev.wakeon.ios`,
  Live Activity extension `dev.wakeon.ios.LiveActivity`.
- Chat Lab (`dev.wakeon.chatlab`, scheme `ChatLab`, derived data `build-lab-device`) is a
  separate app for comparing chat UI libraries; same commands with its scheme and app path.
- **Simulator passing doesn't prove the phone build launches.** The simulator loads
  frameworks from the build folder; the phone only has what's inside the .app. A Swift
  package product declared `type: .dynamic` (e.g. LanguageModelChatUI) is linked but NOT
  embedded unless the target has an Embed Frameworks phase for it (generate-project.py adds
  one). Symptom: crashes at launch on the phone only, and the app doesn't appear under
  Settings › VPN & Device Management. Check before installing: every `@rpath` entry from
  `otool -L` on the app's binaries (minus `libswift*`) must exist in `App.app/Frameworks`.

## Signing (free Personal Team)

- Team `JDR6VAV2RA` ("Kaiser Dandangi") is a free Personal Team: **profiles last 7 days from
  when they are created**, not from install. Reinstalling doesn't extend the app's expiry;
  when the profile expires the app stops launching.
- The CLI can't see the Xcode account, so `-allowProvisioningUpdates` can't make new
  profiles. **Renew by building once in the Xcode GUI**, then CLI builds work again.
- The app and the Live Activity extension have separate profiles with separate expiry dates.
  Check both:
  `for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*; do security cms -D -i "$p" | plutil -extract ExpirationDate raw -o - -; done`
- The paid Developer Program gives 1-year profiles (and TestFlight).
- Nov 11 2026: a CLI build with `-allowProvisioningUpdates` created the new Chat Lab profile
  itself, expiring Nov 2027. So the team now seems able to make 1-year profiles from the CLI;
  check a profile's ExpirationDate before assuming the 7-day rule.
- 2026-11-14: wrong for Wake On. Its profiles (created Nov 7) still expired after 7 days, and a
  CLI build with `-allowProvisioningUpdates` failed with "No Accounts" / "No profiles for
  'dev.wakeon.ios'". Symptom on the phone: "App not available". Fixed by opening the project
  in the Xcode app (`osascript`: `tell application "Xcode" to open ".../WakeOn.xcodeproj"`,
  then `build`); Xcode made **1-year** profiles for the app and the Live Activity (until
  2027-11-14). The first AppleScript to Xcode triggers macOS's "claude wants to control
  Xcode" prompt (Privacy & Security › Automation); only the user can allow it, and it may come
  back after a Claude Code update. AppleScript calls time out (-1712) while the prompt waits.

## Wireless installs (Wi-Fi) and why they fail

- CoreDevice over Wi-Fi needs Bonjour (`_remotepairing._tcp`) **and** direct unicast
  (IPv4 + IPv6 link-local) between Mac and phone. `devicectl device info details` shows
  `transportType` (wired/localNetwork) and `tunnelState`.
- `native/ios/scripts/device-link-check.py` checks each step in order (discovery, addresses,
  reach, tunnel) and gives a verdict. `--watch 60` logs to
  `~/Library/Logs/wake-on-device-link.jsonl`.
- Home network: Bell Home Hub 4000, Bell "Whole Home Wi-Fi"
  (Plume) **on**. It picks the channels itself, the hub's page has no manual channel settings,
  and turning it off also disables any pods. The user chose to keep it on.
- Observed failure: verdict **REACH**. The phone's Bonjour announcements still arrive but it
  answers no ping/TCP/ARP. It lasts hours, with brief recoveries, and leaving and rejoining
  Wi-Fi didn't fix it. Both devices were on 5 GHz. The Mac moves between channels 44 and 149,
  and failures were ~2× likelier on 44, but the problem also happens on 149. Root cause
  unproven; the hub's device list (needs the admin login) showed stale band info for the Mac.
- 2026-11-14: REACH/DISCOVERY failures all night (02:34 to at least 08:54, Mac on channel 44).
  Turning Wi-Fi off and on **on both the phone and the Mac** fixed it at once (09:49, OK over
  `localNetwork`, still channel 44). The Mac's signal there was weak (−69 dBm, MCS 1).
  Try this before the cable; leaving and rejoining on the phone alone didn't help before.
- Bonjour records have a 75-minute TTL, so `dns-sd` can show stale instances. tcpdump needs root.
- **Practical fix: plug in the cable.** Pull logs before plugging in if you want to study a
  live Wi-Fi failure (plugging in tends to clear it).
- An earlier wrong theory ("Wi-Fi dozing") was rejected by the user. Measure before blaming.

## App logs

- `Documents/voice-console.log` (voice and listener events) and `Documents/latency.jsonl`
  (traces) in the app container. Copy with `devicectl device copy from --domain-type
  appDataContainer --domain-identifier dev.wakeon.ios --source Documents/<file>`.
- Keep a copy in the scratchpad, then clear the log after installing a test build
  (`copy to` an empty file) so the next test is easy to read.
- Audio-specific log reading is in the `ios-audio` skill.

## Platform limits (from feature scoping)

- **App Shortcut vs Control:** the same AppIntent underneath. A Control (ControlWidget, needs
  a widget extension) can show state and act as a toggle; a Shortcut can't. Talk to Lobby is
  an App Shortcut assigned to the Action Button.
- **Live Activity** isn't lighter than the app. It allows background presence and skips the
  ~700 ms foregrounding of a normal intent. It can only be started while the app is in the
  foreground.
- **No launch at boot**, and the mic can't start from the background. Shortcuts automations
  (charger, Wi-Fi, CarPlay) could run a "Start listening" intent, which doesn't exist yet.
- **Opening links/apps:** a background app can't. Only the foreground app can, or the user
  tapping a notification, Live Activity or Control, or an App Intent returning `OpenURLIntent`.
  Lobby's web search runs server-side (Responses `web_search`), so no links come back today.
- **Siri:** third-party apps can't send `INPlayMediaIntent` or invoke Siri.
- **Spotify:** no API creates developer apps; use the dashboard (Client ID only, PKCE,
  redirect `wakeon://spotify-callback` planned). The Web API controls playback with Premium
  plus an active device (else `NO_ACTIVE_DEVICE`). App Remote `authorizeAndPlayURI` opens
  Spotify. Plan: Web API, opening Spotify when no device is active (foreground), with a
  notification tap as the fallback when woken in the background.
  Never sign up for accounts on the user's behalf; ask first.
  **Built (2026-11-07):** the minimal version needs no Spotify account. The backend model
  web-searches the open.spotify.com link and calls `play_spotify`. The app hangs up, then opens
  the `https://open.spotify.com/...` link as a universal link (`.universalLinksOnly`), with
  `spotify:<kind>:<id>` / `spotify:search:<query>` as the fallback. A custom scheme makes iOS
  ask "Open in Spotify?" every time; the universal link opens Spotify with no prompt and still
  autoplays (verified 2026-11-07). From the background it posts a
  notification to tap instead (`SpotifyPlayer.swift`). Verified on the phone with Premium:
  opening `spotify:track:<id>` starts playback right away. Test without speaking:
  `devicectl device process launch --terminate-existing dev.wakeon.ios --talk spotify`.
  The `spotify_open` log line may be missing because the app is suspended as Spotify opens.
- **Controlling other apps' playback (verified 2026-11-07, iOS 26, sideloaded debug build):**
  the private `MediaRemote.framework` `MRMediaRemoteSendCommand(command, nil)` (play 0, pause 1,
  toggle 2, stop 3, next 4, previous 5, loaded with `dlopen`/`dlsym`) **works**. It paused and
  resumed Spotify with Wake On in the foreground, and paused it with the phone locked and Wake On
  in the background. Reading state (`MRMediaRemoteGetNowPlayingApplicationIsPlaying`) is
  blocked: it always says false, so don't rely on it. Private API means no App Store; fine for
  this sideloaded app. Built into Lobby as the `control_media` tool (`MediaControl.swift`); the
  call hangs up first, then the command is sent (pause/play twice, ~0.8 s and ~1.8 s after, since
  an exclusive call pauses other apps and they may resume when it ends). Test without a call:
  `--media pause --media-delay N [--autostart]`; with a call: `--talk pause`. Watch out: launching Wake On in the foreground can itself pause other audio,
  so test with "play" on paused music (opening an app never resumes others). And `devicectl
  process launch` silently does nothing while the phone is locked: check it printed
  "Launched application". declare function tools in `session.delegation.responses.tools`.
  The call arrives as `response.event` whose nested `event.type == "response.output_item.done"`
  with `item.type == "function_call"` (`call_id`, `name`, `arguments` JSON string). Reply with
  `{"type":"response.item.create","item":{"type":"function_call_output","call_id":…,"output":"<string>"}}`
  and then `{"type":"response.create"}` (the item alone doesn't resume the backend). Docs:
  developers.openai.com/api/docs/guides/live-delegation.

## House rules for this repo

- Commit straight to master, staging only your own files. Never commit the user's Jev/Laya
  work (root README, pyproject, uv.lock, `docs/jev-*`, `docs/laya-*`, `src/lobby_wake/jev_computer/`,
  `tests/test_jev_*`, `tests/test_laya_computer.py`, the 2026-09-17 notebook entry).
  `.claude/` (skills, launch.json) is tracked: commit changes to it.
- The API key stays out of the repo (Keychain or DEBUG launch environment). Recordings stay
  git-ignored.
- Don't regress the Action Button flow.
