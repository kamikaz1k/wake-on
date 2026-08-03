# Routed library API

Wake On exposes one lifecycle core through two public entry points:

- `WakeListener` is the convenience surface for one immutable wake trigger and
  one delegate.
- `WakeRouter` owns one microphone stream and routes multiple stable trigger
  IDs to independently supervised delegates while allowing only one active
  conversation.

The current CLI deliberately installs one `lobby` route. Multi-route process
configuration and delegate-to-delegate handoff are later product work; the
library boundary no longer needs to change to add them.

## Single-route embedding

```python
from lobby_wake import WakeListener

listener = WakeListener(
    detector,
    lobby_delegate,
    logger,
    sample_rate=16_000,
    trigger_id="hey_lobby",
    route_id="lobby",
)

listener.prepare()
try:
    for frame in audio_source.frames():
        listener.process_audio(frame)
finally:
    listener.close()
```

`prepare()` runs delegate warm-up before the audio loop. `process_audio()` must
be called serially with mono float32 frames from the configured sample rate.
`request_end()` is safe to call from another thread because the underlying
conversation controller serializes end requests.

## Routed daemon embedding

```python
from lobby_wake import WakeRoute, WakeRouter

router = WakeRouter(
    detector,
    routes=[
        WakeRoute.for_trigger("lobby", "hey_lobby", lobby_delegate),
        WakeRoute.for_trigger("timbo", "hey_timbo", timbo_delegate),
        WakeRoute.for_trigger("jigs", "hey_jigs", jigs_delegate),
    ],
    logger=logger,
    sample_rate=16_000,
)
```

Each trigger ID has exactly one owner. A route can own several trigger IDs by
constructing it with a `frozenset`; an empty trigger set is a catch-all and is
primarily used by the backwards-compatible `Orchestrator` wrapper.

The router:

- prepares every configured delegate before listening;
- polls inactive delegates so warm connections and crashed workers can recover;
- maps `WakeEvent.trigger_id` to exactly one immutable `WakeRoute`;
- gives preroll and live audio only to the selected delegate;
- records `active_route_id` for the current exclusive activation;
- rejects unmapped triggers and unavailable delegates without creating a
  conversation generation;
- closes every owned delegate on daemon shutdown.

## Stable trigger identity

`WakeEvent` retains the human-readable detected phrase and adds a normalized
`trigger_id`. For example, `"Hey, Lobby!"` and the decoder label
`"HEY_LOBBY"` both become `hey_lobby`. Routing and authorization use the stable
ID; logs keep both values for diagnosis.

The configured Sherpa keyword file remains the source of recognized keywords.
Adding routes does not create or train keyword models automatically.

## Exclusivity and future handoff

The router owns one `ConversationController`, so all routes share one exclusive
conversation generation. Wake detection is suspended while a route is active.
A delegate can end only the generation whose handle it received.

Direct `handle.handoff(route_id)` is intentionally not part of this phase. A
future handoff must be an atomic router operation that ends the current route,
invalidates its handle, activates the destination, and never exposes an
intermediate window for a competing wake.

## Public surface

The intended embedding surface is:

- `WakeEvent` and stable `trigger_id`;
- `WakeRoute`;
- `WakeRouter` and `WakeListener`;
- `State`, `active_route_id`, `route_status()`, and `conversation_handle`;
- `prepare()`, `process_audio()`, `request_end()`, and `close()`;
- `ConversationDelegate` and the delegate lifecycle dataclasses;
- `ProcessConversationDelegate` for supervised child processes.

The CLI, signal installation, `.env` loading, Sherpa model paths, microphone
selection, and OpenAI configuration are application assembly rather than the
reusable lifecycle API.
