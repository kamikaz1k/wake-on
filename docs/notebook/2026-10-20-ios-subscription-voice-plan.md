# iOS realtime voice on a ChatGPT subscription: plan

- **Date:** 2026-10-20
- **Status:** superseded on 2026-10-25. A ChatGPT plan cannot pay for third-party realtime voice; Wake On now uses the API directly. See [2026-10-25-ios-realtime-voice.md](2026-10-25-ios-realtime-voice.md).
- **Goal:** sign in to a ChatGPT plan from the Wake On iPhone app, then press the
  Action Button to start a realtime voice conversation billed to that plan.

## Findings that shape the plan

1. **No public API covers this.** The ChatGPT plan is not an API credential.
   "Sign in with ChatGPT" is limited to approved partners and covers the
   Responses API only, without audio input.
2. **Codex app-server does.** Codex's experimental `thread/realtime/start` with a
   `webrtc` transport takes a WebRTC SDP offer from any peer. Codex creates the
   call with its own ChatGPT login and returns the answer. Audio then flows
   directly between the peer and OpenAI. OpenAI's pricing page: Voice uses the
   Codex usage budget at $0.05 per minute and "isn't available via API key".
   OpenAI's Codex iOS app works the same way: the phone pairs with a desktop host.
3. **Codex's WebSocket realtime path still requires an API key** (a TODO in
   `realtime_conversation.rs`). Only WebRTC works with a ChatGPT login.
4. **Codex cannot run on the iPhone.** The Mac runs `codex app-server`. The phone
   is only the audio endpoint and the controls. Tokens never leave the Mac.
5. **Login can be driven from the phone.** `account/login/start` with
   `chatgptDeviceCode` returns `verificationUrl` and `userCode`. The phone opens
   the URL and shows the code, so the Mac's `localhost:1455` callback is not
   needed. `chatgptAuthTokens` is marked internal-only; do not use it.
6. **The Codex inside ChatGPT.app is too old.** It is `0.154.0-alpha.6.2`.
   OpenAgents requires 0.159 or later for this WebRTC v3 voice path, so install
   and pin a standalone `codex`.

## Reference implementation: OpenAgents

[OpenAgentsInc/openagents](https://github.com/OpenAgentsInc/openagents) ships this
exact split. Files worth copying from, at the commit reviewed on 2026-10-20:

| Piece | File | What to take |
|---|---|---|
| iPhone WebRTC peer | `apps/ios/OpenAgents/Voice/CodexVoicePeer.swift` | Whole design: `stasel/WebRTC`, unified plan, ordered `oai-events` data channel, track created muted, full ICE gathering before sending the offer, `playAndRecord`/`voiceChat` session, end on interruption, earpiece/speaker routing |
| Host start (phone offer) | `crates/harness/src/codex/realtime.rs` → `start_external` | Exact `thread/realtime/start` params; wait for both `thread/realtime/started` and `thread/realtime/sdp` |
| Eligibility probe | same file → `probe_details` | `account/read` must be `chatgpt`; `config/read` must have no custom provider or realtime URL overrides; `thread/realtime/listVoices` |
| Phone ↔ host protocol | `crates/proto/src/voice/remote.rs` | prepare → negotiate (offer/answer) → confirm (unmute) → 5 s heartbeat, 15 s lease, random attempt keys, SDP ≤ 64 KB, never logged |
| Live Activity | `apps/ios/OpenAgentsShared/VoiceActivity.swift` | `LiveActivityIntent` mute and end buttons |

The start parameters they send:

```json
{"threadId": "…", "transport": {"type": "webrtc", "sdp": "<phone offer>"},
 "version": "v3", "outputModality": "audio", "realtimeSessionId": "<uuid>",
 "clientManagedHandoffs": false, "includeStartupContext": true,
 "realtimeStartInstructions": "…", "initialItems": [{"role": "developer", "text": "…"}],
 "voice": "<optional, from listVoices>"}
```

OpenAgents starts calls only while its app is in front. It has no Action Button
or wake-word start.

## Architecture

```text
iPhone (Wake On)                        Mac (lobby-wake voice host)          OpenAI
─────────────────                       ───────────────────────────          ──────
Action Button / button / wake ─┐
WebRTC peer ── offer ──────────┼─ WSS ─▶ bridge ── JSON-RPC stdio ──▶ codex app-server ──▶ ChatGPT backend
            ◀─ answer ─────────┘         (pairing secret, lease)           (ChatGPT login)
WebRTC audio + oai-events ◀════════════════════ direct media ═════════════════════════════▶ GPT-Live
```

Only signaling passes through the Mac. Media goes straight from the phone to
OpenAI, so the Mac only needs to be reachable by the phone (same Wi-Fi or
Tailscale).

## Phases

### Phase 0: prove it on the Mac (half a day)

- Install a standalone `codex` 0.159 or later and pin the version.
- Copy `webrtc_spike.py` to a new test that keeps the browser peer but replaces
  the `/v1/realtime/calls` POST with `codex app-server`: `initialize`,
  `account/read`, `thread/start`, `thread/realtime/start` (webrtc, v3, audio),
  wait for `thread/realtime/sdp`, then return the answer to the browser.
- **Done when:** a two-way spoken conversation works with no `OPENAI_API_KEY`
  set, and the session shows up against the Codex usage budget. Record the
  Codex version and the event sequence in a notebook entry.

### Phase 1: Mac voice host and phone sign-in

- New `lobby_wake/voice_host/` module and a `lobby-voice-host` command. It owns
  one `codex app-server` child process and exposes an authenticated WebSocket.
- Pairing: the host prints a QR code holding the URL and a random 256-bit
  secret. The phone scans it and stores the secret in the Keychain. Reject any
  connection without it.
- Sign-in from the phone:
  1. The phone asks for account status. The host calls `account/read`.
  2. If not signed in with ChatGPT: the host calls `account/login/start` with
     `{"type": "chatgptDeviceCode"}` and sends `verificationUrl` and `userCode`
     to the phone.
  3. The phone shows the code and opens the URL in an
     `ASWebAuthenticationSession` or Safari.
  4. The host waits for the `account/login/completed` and `account/updated` notifications,
     then sends the email and plan to the phone.
  5. Sign out calls `account/logout`.
- **Done when:** the phone shows "Signed in as … (Plus/Pro)" and survives a
  host restart.

### Phase 2: in-app "Talk" button

- Add the WebRTC framework through `scripts/setup.sh`: a pinned `stasel/WebRTC`
  xcframework with a SHA-256 check, like the Sherpa download. Teach
  `generate-project.py` to link it.
- `CodexVoicePeer.swift`, modelled on OpenAgents'.
- Host side: prepare (probe eligibility, open an idle thread) → negotiate (phone
  offer → `thread/realtime/start` → answer) → confirm (phone unmutes) →
  heartbeat. If heartbeats stop for 15 s, call `thread/realtime/stop`, so an
  abandoned call never keeps billing.
- Microphone handover: stop the wake listener's `AVAudioEngine` before WebRTC
  takes the microphone, and rearm it after the call ends. Two capture paths
  must never run at once.
- Live Activity with mute and end buttons, so the call can be controlled with
  the phone locked.
- **Done when:** tapping Talk gives a two-way conversation that keeps going with
  the screen locked, ends cleanly from the Live Activity, and the wake listener
  resumes afterwards.

### Phase 3: Action Button

- Add an App Intent ("Talk to Lobby") and publish it with
  `AppShortcutsProvider`, so it can be picked in Settings › Action Button.
- First version: the intent brings the app forward (`supportedModes` /
  `openAppWhenRun`) and starts the Phase 2 call right away. This is the reliable
  route. A locked phone asks for Face ID first.
- Experiment: start without unlocking. Try `AudioRecordingIntent` with a Live
  Activity started from the intent, and separately try starting while the wake
  listener already holds an active background audio session. Apple developer
  forum reports say a cold start from the background often fails
  (`setActive` errors, "Target is not foreground"). Keep the foreground version
  as the fallback.
- **Done when:** one Action Button press goes from the home screen to a live
  conversation in about 2 seconds or less.

### Phase 4: wake word starts the call (optional)

- "Hey Lobby" triggers the same start as the Action Button. iOS rules for
  starting from the background are the same as in Phase 3.
- The 2 s of audio saved before the wake can't be pushed into a WebRTC track
  after the fact. Test `thread/realtime/appendAudio` on a WebRTC session.
  Otherwise, play a short "go ahead" sound and drop the saved audio.

## Decisions needed

1. **What Codex can do during a call.** With `clientManagedHandoffs: false`,
   the voice model can hand tasks to the Codex agent on the Mac, which can run
   commands and edit files. Options: a read-only sandbox in an empty working
   directory (safest), or this repo's existing computer-use tools. Decide before
   Phase 2.
2. **How the phone reaches the Mac when away from home.** Same Wi-Fi works with
   no setup; Tailscale works anywhere. A public relay is out of scope.

## Risks

- `thread/realtime/*` is marked EXPERIMENTAL and changes between Codex
  releases. Pin the Codex version and keep a recorded protocol test.
  OpenAgents keeps one at `crates/harness/tests/fixtures/codex/voice-0.159.0.json`.
- The call runs on Codex's private backend route through OpenAI's own client.
  That is the documented way Codex voice works, but OpenAI can change limits,
  pricing or eligibility.
- The Mac must be awake and running the host. Phase 1 can keep it awake while
  the host runs, but a closed laptop lid ends it.
- Cost: $0.05 per minute plus the tokens of any delegated task, from the same
  usage budget as Codex.
