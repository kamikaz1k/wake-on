# Peekaboo MCP adapter: supervised process boundary

- **Date:** 2026-08-09
- **Status:** mapping Adapter superseded on 2026-08-22; supervised MCP transport retained

## Goal

Connect the provider-neutral `ComputerExecutor` contract to pinned Peekaboo
v3.9.10 without yet performing the reversible TextEdit fixture.

## What was implemented

- A supervised stdio MCP client with bounded frames and request timeouts.
- Explicit support for standard newline-delimited MCP JSON and legacy
  `Content-Length` framing.
- Initialization, initialized notification, tool discovery, and tool calls.
- Hard cancellation by terminating the Peekaboo child process. The next
  prepare or observation starts a new process and MCP session.
- A Peekaboo executor that verifies version 3.9.10 and its required tool
  catalog before becoming ready.
- Snapshot IDs from `see` are preserved as observation revisions and passed to
  every snapshot-bound action.
- Peekaboo stale/invalidated snapshot errors map to `StaleObservationError`,
  causing the worker to observe and plan again.
- Only the selected tools are mapped: `see`, `click`, `type`, `set_value`,
  `perform_action`, `hotkey`, `scroll`, `app`, and narrowly scoped `window`.
  `permissions` is used only during preparation.

## Discoveries

The release archive
`peekaboo-macos-universal.tar.gz` matched the GitHub release SHA-256:

```text
02647a5353fa95c3d37cd2d20ca9e8eb5df5bc351c133d83f3b4712b73ca7b5c
```

The actual binary reports Peekaboo 3.9.10 and successfully completed MCP
initialization and required-tool discovery through the adapter.

Peekaboo's Swift test fixture uses `Content-Length` framing, but the released
binary's official Swift MCP `StdioTransport` uses newline-delimited JSON. The
first real handshake timed out because the prototype followed the fixture.
Supporting both framings fixed the handshake. Timeouts stop the child process
so a late response cannot desynchronize the next request.

The real `permissions` call currently reports both Screen Recording and
Accessibility as not granted for this execution context. No screenshot or UI
action was attempted. The binary also emits a Swift checked-continuation leak
warning while checking local permissions; this is recorded as a redacted
diagnostic code rather than copying arbitrary child-process stderr into logs.

## Deterministic validation

The adapter tests cover:

- both stdio framing formats;
- initialize, tool discovery, and tool calls;
- malformed responses and bounded timeouts;
- cancellation during an in-flight call and clean restart;
- required tool and pinned version checks;
- observation revision and screenshot parsing;
- every allowed action mapping;
- stale-snapshot error mapping.

## TODO: reversible TextEdit fixture

Leave the live fixture pending until the user grants Screen Recording and
Accessibility to the app/terminal context that launches Peekaboo. Then run a
bounded task: open TextEdit, create an unsaved document, type a known sentence,
verify it, and close without saving. Record cold/warm observation latency,
action latency, cancellation response, and repeated reliability.

## 2026-08-22: application startup is observable state

The first live TextEdit task failed before planning because Peekaboo `see`
reported `Application 'TextEdit' not found`. The worker previously assumed that
a UI snapshot must exist before every decision, which made its already-mapped
generic `app launch` action unreachable.

The immediate fix represents a missing process as
`ComputerObservation(available=False)`. The planner receives that state, may
select the policy-allowed `LAUNCH_APP` action, and then plans from a fresh
observation. A deterministic harness now covers absent → launch → running, so
this is not TextEdit-specific behavior.

Peekaboo would ideally expose a stable structured error code such as
`application_not_running`, with the requested target in error data, and make
the recovery relationship to `app launch` explicit in its MCP tool
descriptions. Version 3.9.10 instead returns human-readable error text, so the
adapter currently classifies that text. This is isolated inside the Peekaboo
adapter but is intentionally treated as a compatibility shim.

The compatibility boolean was subsequently replaced with typed
`ApplicationAvailability`: `observable`, `not_running`,
`running_not_ready`, `inaccessible`, and `unknown`. Snapshot-bound actions are
accepted only from `observable`; generic launch/focus actions drive recovery;
and repeated not-ready recovery is bounded. New applications therefore
contribute identity metadata and policy, not custom lifecycle code.

MCP diagnostics now report the exact tool, JSON-RPC method, elapsed duration,
configured timeout, and typed error code without logging tool arguments or UI
content. A real TextEdit rerun produced:

```text
tool=see error_type=MCPRequestTimeout error_code=request_timeout
mcp_method=tools/call timeout_seconds=5
tool=app completed
availability=running_not_ready
```

Further isolation showed that Peekaboo can list the TextEdit process and its
window, permissions are granted, and an image-only capture completes in about
1.2 seconds. The image is a valid blank 500×500 TextEdit document. `see` still
times out when accessibility element detection is enabled, even with bounded
tree depth, child count, and element count, and local-only execution emits a
Swift checked-continuation leak warning. This narrows the current fault to
Peekaboo's TextEdit accessibility-element observation path rather than WakeOn's
MCP framing, app discovery, screenshot permission, or screenshot capture.

## 2026-08-22: switch the active spike to Chrome

TextEdit remains configured for historical regression work, but the active
end-to-end fixture moves to Google Chrome. Peekaboo 3.9.10 already exposes a
first-class `browser` MCP tool backed by Chrome DevTools MCP, so WakeOn does not
add another browser provider or browser abstraction.

For the Google Chrome application target, the existing Peekaboo executor now:

- observes `browser status` before connection and `browser snapshot` after it;
- passes native Peekaboo browser payloads through the supervised action loop;
- supports current-page navigation, new pages, page selection, snapshots, and
  browser `press_key` scrolling such as `PageDown`;
- keeps task cancellation and asynchronous voice behavior unchanged.

The local status probe detected Chrome 151 but reported Chrome DevTools MCP as
disconnected. A live trial therefore requires enabling remote debugging at
`chrome://inspect/#remote-debugging` and accepting Chrome's connection prompt.
The deterministic MCP fixture covers disconnected → connect → snapshot plus
native payload forwarding for navigation, new-page creation, and scrolling.
