# Simulator validation — 2026-10-12

Environment: Xcode 26.6 (17F113), iPhone 17 Pro simulator running iOS 26.5.
The default command-line developer directory was not changed; commands used
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Passed

- Debug simulator build.
- Unsigned Release build for generic physical iOS devices.
- Five XCTest cases: wrapped preroll/tail continuity, early wake, actual-model
  detection plus exact handoff, ten seconds of silence, and 48→16 kHz streaming
  conversion preserving detectability.
- Foreground fixture scenario: `HEY_LOBBY`, foreground state, running audio engine,
  exact 80,000-sample handoff.
- Background fixture scenario: the app starts audio in the foreground, Simulator
  Safari is launched, and the real Sherpa model detects `HEY_LOBBY` while the app
  reports `UIApplication.State.background`. The engine is still running.
- Paced silence scenario: no wake, with the audio engine still running.
- Handoff screen visually inspected after returning to the existing app process.
  See `handoff.png`.

Both positive scenarios captured frames **21,760 through 101,759**, with the wake
at frame **53,760**. This is 32,000 preroll samples plus 48,000 subsequent samples
at 16 kHz: **5.00 seconds total**. The buffer equals that slice of the supplied
source exactly. The raw report's `endFrame` is exclusive.

The fixture was the repo's locally stored, approved
`recordings/positive/positive-001-quiet.wav`, preceded by two seconds of silence
and followed by padding. It was supplied in 20 ms blocks in real time. These
checks exercise the actual packaged ONNX model, not a synthetic wake callback.
Audio is not included in the saved validation reports.

## Limits and remaining device checks

- Fixture mode replaces detector microphone samples with a recording while an
  actual microphone engine runs. This proves the model/buffer/state path, **not
  acoustic microphone pickup**.
- Simulator background execution does not prove real-device suspension behavior,
  locked-screen reliability, battery consumption, Bluetooth routing, or recovery
  after calls/Siri. Test those on an iPhone using the parent README.
- A silence pass is not a representative false-activation evaluation.
- Playback is implemented; listening to its audio output still needs a manual
  check on the target device.
- Notification delivery and tapping a notification to foreground the app were
  not verified. Automatic approval review blocked accepting notification access
  without explicit permission; the simulator tests continued with notifications
  denied. No permission bypass was used.
- No automatic foreground launch is implemented: iOS requires user interaction.
- No Realtime voice integration or network audio transmission is included.

The simulator Mac was locked during the resumed session. Automated `simctl`
transitions and screenshots remained available; interactive Mac UI access was
not used to bypass the lock.
