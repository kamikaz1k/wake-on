# Known iOS restrictions

What iOS doesn't let Pixie do, and what we do instead. Each item was found on the phone (iPhone
17 Pro, iOS 26); the dates say when. Audio details are in the `ios-audio` skill
(`.claude/skills/ios-audio/SKILL.md`), and other platform limits are in `ios-device-dev`.

"Phone builds" are the Debug builds installed from Xcode or `deploy-phone.py`. "TestFlight builds"
are the Release builds `testflight.sh` uploads; App Store Connect checks them.

## Controlling other apps' playback

| | Phone builds | TestFlight builds |
|---|---|---|
| Pause, resume, skip, go back (`control_media`) | Yes, in any app, phone locked too | No |
| What Pixie says when asked | Does it | "iOS doesn't allow it in this version of Pixie" and points to Control Center |

- The only way to send Control Center's play/pause commands to another app is Apple's private
  MediaRemote framework (`MRMediaRemoteSendCommand`). App Store Connect rejects private APIs, so
  Release builds leave it out entirely and `testflight.sh` refuses to upload a binary that names
  it (`MediaControl.available`, 2026-11-07).
- Even MediaRemote can't read what's playing: `MRMediaRemoteGetNowPlayingApplicationIsPlaying`
  always says false, so commands are sent blind.
- Public alternatives, none of them general:
  - Apple Music only: `MPMusicPlayerController.systemMusicPlayer` controls the Music app.
  - Spotify only: its Web API, with a Premium account and a registered developer app.
  - Pause by taking over the audio: activating Pixie's own (non-mixable) audio session pauses
    other apps, and letting go without `.notifyOthersOnDeactivation` should keep them paused. It
    can't resume or skip, doesn't work from the background (below), and some apps may resume
    anyway. Considered and not built (2026-11-27).
- Since 2026-11-27, TestFlight builds tell both models media control isn't available
  (`MediaControl.unavailableInstructions`), so Pixie says so instead of trying Spotify or
  claiming she paused something.
- Since 2026-11-28, Settings › Music › Connect Spotify signs in to the user's own Spotify
  account (OAuth with PKCE, `SpotifyAccount`). Then `control_media` is offered in every build
  and goes to Spotify's Web API first, on whichever device is playing. Spotify's limits: its
  app "Pixie" is in Development Mode, so only Premium accounts added under User Management in
  Spotify's developer dashboard can connect (at most 5). When nothing has played for a while,
  Spotify has no active device and resume fails; Pixie posts a notification saying so.

## The microphone and audio session in the background

- **The microphone can't start from the background.** Start it in the foreground, or keep an
  already-running session alive. This is why "Hey Pixie" keeps a listener running.
- **A background app can't interrupt other audio** (`'!int'`, OSStatus 560557684): activating
  an exclusive session, changing the category, even a mode-only change to `.voiceChat` is
  refused. Wake-word calls therefore stay in the listener's shared session, with weaker echo
  cancellation than Action Button calls (2026-11-07).
- A refused session change can still change the route: once Pixie played through the earpiece
  afterwards. Never try-and-ignore session changes from the background.

## Opening things from the background

- A background app can't open URLs or other apps (Spotify, YouTube, Maps, Safari). When a call
  in the background needs to, Pixie posts a notification to tap instead.
- A Live Activity can only be started while the app is in the foreground.
- Exceptions: the user taps a notification, Live Activity or Control, or an App Intent continues
  in the foreground.

## Starting Pixie

- No launch at boot, and no listening after a restart until the app is opened.
- Siri can't be invoked by a third-party app, and `INPlayMediaIntent` can't be sent to other apps.
- The Action Button runs an App Shortcut; a Control (widget extension) is the same intent
  underneath but can also show state.

## Signing and distribution

- Free Personal Team profiles last 7 days; the paid team's last a year (`ios-device-dev`).
- Builds must be uploaded with the iOS 27 SDK (Xcode 27) from April 2027 (App Store Connect
  warning, 2026-11-27).
- External TestFlight testers only get builds that passed Apple's beta review; internal testers
  get every build.
