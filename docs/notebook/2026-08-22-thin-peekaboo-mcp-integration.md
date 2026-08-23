# Thin Peekaboo MCP integration

- **Date:** 2026-08-22
- **Status:** implemented and covered by deterministic tests; live Chrome regression pending

## Problem

The first computer-use implementation introduced a provider-neutral action
vocabulary, application availability state machine, structured planning schema,
macOS prompt bundle, and a Peekaboo mapping layer. Live Chrome trials showed
that this translation lost information from Peekaboo's MCP Interface. A model
produced browser-style `key` while Peekaboo's native `hotkey` expected `keys`,
and WakeOn's special application logic confused Chrome page state with macOS
window state.

The intended product work was narrower: keep Realtime voice responsive while a
computer task runs, and integrate Peekaboo idiomatically.

## Decision

Keep two earned seams:

1. `StdioMCPClient` remains a deep Module for MCP framing, request correlation,
   timeouts, hard process cancellation, restart, and stderr draining.
2. The Realtime asynchronous job Interface remains responsible for immediate
   acceptance, one active task, generation suppression, task-only cancellation,
   and voice-priority completion delivery.

Replace the planner/action/executor stack with one `PeekabooTaskRunner`. It:

- discovers the live Peekaboo catalog with `tools/list`;
- converts each definition mechanically to an OpenAI function definition while
  preserving its input schema;
- forwards selected tool names and parsed argument objects unchanged to
  `tools/call`;
- returns native MCP error results to the model so it can recover;
- omits Peekaboo's nested `agent` tool because the background Responses loop
  already owns planning;
- stops the MCP child when cancellation is accepted.

Peekaboo's `PEEKABOO_ALLOW_TOOLS` filtering is now the authoritative way to
restrict the executable tool catalog. WakeOn still checks the requested target
application before starting and tells the model the application scope, but it
does not claim hard application enforcement inside every MCP call.

## Removed implementation

The deletion removed the custom computer action/risk/observation types,
application readiness and revision state machine, approval flow, custom
Responses decision schema, Peekaboo action mapping, Chrome-specific mapping,
and modular prompt bundle. These Modules had one Adapter and failed the deletion
test: removing them made their complexity disappear rather than reappear in
callers.

Historical entries remain in this notebook because they record why those ideas
were tried and what the live failures taught us.

## Deterministic validation

Tests cover:

- immediate task acceptance while the Responses request is blocked;
- one-active-task serialization;
- unchanged MCP schema exposure;
- unchanged tool-name and argument forwarding;
- multi-step tool result feedback and final text;
- cancellation interrupting an in-flight MCP call;
- cancellation dominating the resulting late transport failure;
- continued microphone upload and voice-priority completion delivery in the
  existing Realtime tests.

## Next experiment

Repeat the Chrome navigation, new-tab, form submission, and scrolling trial
with native AEC enabled. Confirm that the model now selects arguments from the
live Peekaboo schemas and that barge-in remains responsive during the task.
