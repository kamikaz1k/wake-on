# Naive macOS Harness computer-use integration

- **Date:** 2026-08-23
- **Status:** implementation and local execution path verified; live voice-agent trial next

## Why this spike exists

The thin Peekaboo MCP integration was functional, but a simple Chrome task used
many sequential Responses turns and a large repeated MCP tool catalog. The
measured task latency and token usage were too high for an interactive voice
assistant. macOS Harness recommends one Python program per genuine decision
point, allowing deterministic actions and verification to be bundled.

## Implementation

The existing Realtime-facing asynchronous contract remains unchanged:
`use_computer`, `steer_computer_task`, and `cancel_computer_task` still return
immediately and computer work remains behind the foreground voice path.

The default executor is now a `MacOSHarnessClient` presented to the existing
computer planner as one operation, `run_macos_harness(code)`. Each call starts a
supervised `macos-harness` child, sends the generated Python over stdin, and
returns bounded stdout/stderr. When a printed result contains a PNG path, the
last image is attached to the Responses function output at low image detail.
Cancellation terminates the active child. Steering and stale-result suppression
continue to be owned by the existing task runner.

This is intentionally a naive trust boundary. The stock macOS Harness namespace
includes `mac`, `browser`, `Path`, and `subprocess`. Application scoping is
currently an agent instruction and admission check, not a Python capability
sandbox. Hardening is deferred until the live end-to-end behavior is useful.

## Verification

- macOS Harness `0.1.2` is pinned in the project environment.
- Telemetry is disabled for every child invocation with
  `MACOS_HARNESS_TELEMETRY=0`.
- `macos-harness doctor` reported Accessibility, Screen Recording, and event
  posting granted. Input Monitoring is not required.
- A real read-only capture of the running ChatGPT app succeeded.
- The WakeOn adapter launched the real harness and returned both text and image
  content (`612` text characters and `507,820` base64 image characters).
- Deterministic tests cover execution, screenshot handoff, planner round-trip,
  and cancellation.
- Full suite: `114 passed`; Ruff clean.

During verification, app discovery exposed an old seven-hour WakeOn/Peekaboo
trial tree. Its listener, process delegate, and Peekaboo MCP child were confirmed
to belong to the previous trial and terminated cleanly.

## Next experiment

Run the normal native-AEC voice listener with the default macOS Harness backend.
Start with a bounded Chrome navigation/scroll task and a read-only ChatGPT
inspection. Compare visible time-to-first-action, total task latency, Responses
turn count, input tokens, and cost with the Peekaboo journal baseline.
