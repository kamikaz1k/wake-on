# Interruptible computer subagent

- **Date:** 2026-08-23
- **Status:** interface and deterministic tests implemented; live voice steering pending

## Finding

Peekaboo supplies computer tools but not free reasoning. WakeOn's computer
worker is a separate OpenAI Responses loop using `OPENAI_API_KEY`, independent
of the Realtime voice model's context. Peekaboo's own agent similarly needs a
configured model provider unless it is pointed at a local provider.

The earlier task boundary supported start and cancel but not a conversational
correction such as “actually, don't submit that; open Help instead.” Treating
that as cancel-then-start loses task identity and makes late results harder to
order.

## Decision

The computer-task Interface now supports:

- `start(goal, application) -> task_id`
- `steer(task_id, revised_goal)` while retaining the task ID
- `cancel(task_id, reason)` as a terminal operation
- `poll_events()` for progress, steering acknowledgement, and terminal results

Steering increments a goal revision. If a model response returns after a new
revision was accepted, its stale plan is discarded before any tool call is
started. If steering arrives during a Peekaboo call, that already-running UI
action reaches its safe boundary; no later action from the stale plan runs, and
the agent receives the newest goal with an instruction to re-observe.

Cancellation remains dominant over late model and MCP results. A blocking
OpenAI HTTP request is not physically aborted by the current `urllib` transport,
but its response cannot act or complete the task after cancellation. A future
cancellable HTTP transport may reduce stop latency without changing the public
Interface.

## Context-size correction

The built-in Peekaboo agent revealed that raw MCP response envelopes should not
be copied into model history. WakeOn now returns bounded text, compact binary
content descriptors, or concise errors. This removes raw metadata and encoded
screen content that caused the Chrome trial to request 153,723 tokens and hit
the 200,000 TPM limit.

## Validation

Deterministic tests prove that a revision arriving during an in-flight model
request prevents the stale tool call, that the revised goal reaches the next
turn under the same task ID, and that only compact MCP text reaches model
history. The full suite passes; a live barge-in-and-steer trial remains.

## Cost monitoring follow-up

The computer Responses loop now reads exact `usage.input_tokens`, cached input,
and output tokens from every response. At the standard `gpt-5.4-mini` rates
verified on 2026-08-23—$0.75/M input, $0.075/M cached input, and $4.50/M
output—it logs per-request and cumulative task cost. A pre-request payload
estimate and post-response exact accounting enforce a configurable ceiling,
defaulting to $0.25 per computer task. The budget dominates a returned model
plan: if the response crosses the ceiling, its proposed UI calls do not run.
