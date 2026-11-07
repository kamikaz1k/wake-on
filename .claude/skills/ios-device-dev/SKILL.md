---
name: ios-device-dev
description: Wake On iPhone build/install/debug playbook - building and installing on the physical phone with xcodebuild + devicectl, free Personal Team signing and 7-day profile expiry, wireless (Wi-Fi) install failures and the device-link-check diagnostics, pulling app logs, and iOS platform limits learned while scoping features (Live Activities, App Intents vs Controls, opening URLs, Spotify, background launch). Use before installing a build on the phone, when an install or devicectl command fails, when the app stops launching, or when scoping a new iOS feature.
---

# Building, installing and debugging Wake On on the iPhone

Learned the hard way in Oct–Nov 2026. Check facts still hold before relying on them.

## Build and install (phone)

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
  `spotify:<kind>:<id>` (or `spotify:search:<query>`). From the background it posts a
  notification to tap instead (`SpotifyPlayer.swift`). Verified on the phone with Premium:
  opening `spotify:track:<id>` starts playback right away. Test without speaking:
  `devicectl device process launch --terminate-existing dev.wakeon.ios --talk spotify`.
  The `spotify_open` log line may be missing because the app is suspended as Spotify opens.
- **GPT-Live phone-side tools:** declare function tools in `session.delegation.responses.tools`.
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
