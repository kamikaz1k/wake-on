# Peekaboo computer-agent latency is above the product target

- **Date:** 2026-08-23
- **Status:** live result confirmed too slow; root cause divided between sequential model turns and Peekaboo slow paths

## Product expectation

WakeOn is intended to make voice-triggered delegation feel immediate. For a
simple computer request such as opening Chrome and navigating to a page, the
expected experience was a visible effect within a few seconds—not a background
acknowledgement followed by roughly half a minute without meaningful UI change.

The current implementation does preserve the foreground properties we wanted:
Realtime voice remains responsive, microphone upload continues, barge-in works,
and computer execution happens asynchronously. Nevertheless, the computer task
is too slow for the use cases originally imagined. Responsiveness of the voice
channel does not compensate for delayed computer action.

## Live WakeOn observation

The tested request targeted Google Chrome through the thin, schema-driven
Peekaboo MCP worker using `gpt-5.4-mini`.

| Local time | Event |
| --- | --- |
| 08:31:35 | Computer task accepted and first Responses request sent |
| 08:31:38 | First computer-model response returned |
| 08:31:39 | Peekaboo `app` completed |
| 08:31:41 | Peekaboo `browser` completed |
| 08:31:43 | Peekaboo `window` failed |
| 08:31:44–08:31:48 | Peekaboo `see` observation |
| 08:31:50 | `hotkey` completed; first likely visible action |
| 08:31:52 | `type` completed; first definitely visible action |
| 08:31:54–08:31:57 | Second `see` verification |
| 08:31:59 | Computer task completed |
| 08:32:00 | Voice announced completion |

Measured outcome:

- about 3 seconds to the first computer-model decision;
- about 15–17 seconds from acceptance to meaningful visible interaction;
- about 24 seconds for the computer task itself;
- about 26 seconds from the user's speech ending to spoken completion;
- eight sequential Responses calls for seven Peekaboo operations;
- 135,703 input tokens, including 98,560 cached tokens, and 187 output tokens;
- estimated computer-agent cost of $0.036091.

This was not a cold-start or wake-handoff problem. Peekaboo MCP had already
listed its tools, the computer runner was ready, and OpenAI Realtime was
preconnected before the wake phrase. The delay accumulated after task
acceptance.

## Where the time went

The main multiplier was one model round trip per action. Each Responses call
took roughly one to three seconds, and the agent made eight of them. The action
sequence also wandered through `app`, `browser`, and a failed `window` call
before falling back to visual/accessibility interaction. Two `see` calls added
several seconds and large textual UI observations to subsequent model context.

Intermediate progress was logged but intentionally not spoken while the voice
conversation remained active. That makes the delay feel less transparent, but
announcing more progress would not solve the underlying time-to-action problem.

## Peekaboo's published performance evidence

Peekaboo publishes local primitive baselines, not an end-to-end agent latency
baseline. Its documented December 2025 reference measurements include:

- `see` p95 of approximately 0.97 seconds;
- `click` p95 of approximately 0.18 seconds;
- `scroll` wall p95 of approximately 0.30 seconds;
- system menu list-all wall p95 of approximately 0.61 seconds.

Source: [Peekaboo tool testing and performance checks](https://github.com/openclaw/Peekaboo/blob/main/docs/testing/tools.md).

The repository records natural-language agent smoke runs but does not publish
p50 or p95 completion latency for multi-step agent tasks. Its testing notes say
that non-tmux invocations beyond quick dry runs can time out, which establishes
that long agent runs are known operationally but does not provide a useful
expected-latency target.

## Public issue research

A search of Peekaboo's public issue history did not find a broad, widely
reported issue asserting that all Peekaboo agent tasks consistently take around
30 seconds. It did find narrower performance and timeout modes relevant to the
observed experience:

- [`see --mode screen` 10-second timeout on an external-display path](https://github.com/openclaw/Peekaboo/issues/81);
- [`see` window capture continuation leak and timeout](https://github.com/openclaw/Peekaboo/issues/127);
- [native image size causing context exhaustion, context poisoning, and transport latency](https://github.com/openclaw/Peekaboo/issues/218);
- [incomplete accessibility reads and misleading Bridge failure behavior, including apps without visible windows](https://github.com/openclaw/Peekaboo/issues/596).

These do not prove a universal agent-latency problem, but they show that capture,
window resolution, incomplete accessibility trees, and oversized observations
have produced multi-second or timeout-scale delays in real configurations.

## Local direct Peekaboo reproduction

Outside the WakeOn agent loop, the pinned Peekaboo binary was measured directly:

```text
Peekaboo version: 3.9.10
Command: peekaboo inspect-ui --app "Google Chrome" --max-elements 200 --no-remote --json
Result: Chrome was running but Peekaboo found no windows or dialogs
Wall time: 22.87 seconds
```

This proves that the installed Peekaboo build has at least one slow failure path
on this Mac. It does not explain the entire successful navigation run: the MCP
calls in that live run completed in roughly zero to four seconds each. The
successful task's total delay was primarily the accumulation of model turns,
with Peekaboo observation latency as a secondary contributor.

## Version gap

WakeOn currently pins Peekaboo 3.9.10, released 2026-08-03. The current Peekaboo
release found during this investigation is 4.2.2, released 2026-08-20. Its notes
describe bounded accessibility observers and command deadlines, reused Bridge
handshakes, and improved responsiveness for long-running automation.

Peekaboo 4 is a breaking command-surface release, although WakeOn's MCP
integration discovers live schemas instead of hard-coding the old action
vocabulary. An upgrade should therefore be evaluated side-by-side rather than
silently replacing the pinned binary.

Sources:

- [Peekaboo 4.2.2 release](https://github.com/openclaw/Peekaboo/releases/tag/v4.2.2)
- [Peekaboo 4.0 migration release](https://github.com/openclaw/Peekaboo/releases/tag/v4.0.0)

## Current conclusion

The approximately 24-second task is not an expected consequence of wake-word
detection, Realtime preconnection, or asynchronous delegation. It is the result
of an agent architecture that serializes many remote model decisions, combined
with some relatively expensive or pathological Peekaboo operations.

For an obvious navigation task, an optimized implementation should target
roughly 5–10 seconds end to end. Consistently reaching approximately 3–5 seconds
will likely require a single planning turn that emits a bounded sequence of
actions, rather than returning to the model after every individual action.
Primitive Peekaboo performance alone cannot make an eight-turn remote agent
feel immediate.

## Next useful experiment

Do not broaden the current integration before resolving this latency question.
The bounded next experiment is:

1. Install Peekaboo 4.2.2 alongside 3.9.10 without replacing the pinned binary.
2. Benchmark `app`, `inspect_ui`, `see`, `browser`, and a complete built-in
   `peekaboo agent` task on both versions.
3. Repeat the identical task through WakeOn and preserve per-model-turn and
   per-MCP-call timings.
4. Compare the current sequential loop with a single-plan, sequential-execution
   experiment that retains cancellation and steering boundaries.
5. Decide whether the achievable latency meets the intended product experience
   before investing further in computer-use capabilities.

The existing listener remains useful as a correctness prototype, but the live
result should not be treated as an acceptable latency baseline.
