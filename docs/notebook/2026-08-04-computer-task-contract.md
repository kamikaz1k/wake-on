# Computer-task contract and deterministic worker

- **Date:** 2026-08-04
- **Status:** provider-neutral contract implemented; Peekaboo adapter next

## Goal

Add the safety and lifecycle seam for computer use before granting a real
desktop executor access. Computer use remains a capability of Lobby's reference
delegate, not part of WakeOn's wake routing or generic delegate protocol.

## Decisions

The worker separates three roles:

```text
planner: task + fresh observation + history → next action or completion
policy: application/action allowlists + approval requirements
executor: prepare + observe(revision) + act(revision) + cancel
```

The public task service supports start, status, progress events, expiring
approval, approval rejection, generation-scoped cancellation, completion,
failure, and close. It owns only one active task. A later OpenAI planner and the
selected Peekaboo v3.9.10 executor can be inserted without changing this
lifecycle.

## Safety behavior implemented

- A target application cannot even be observed unless it is allowlisted.
- Every action must match both the application and action-kind allowlists.
- Approval events include the action, risk classification, and expiry.
- The worker observes again after approval. If the revision changed, it does
  not execute the action; it reports stale state and asks the planner again.
- The executor also receives the planned revision and can reject a race that
  occurs after the worker's check.
- Cancellation is scoped to task ID and generation. A stale generation cannot
  cancel the current task.
- Accepted cancellation immediately calls the executor's cancellation hook.
  Any action or completion returned afterward is discarded.
- Ordinary logs omit user intent, accessibility text, screenshots, action
  parameters, and result summaries.

## Deterministic validation

Nine fake-executor tests cover:

1. start → action progress → completion;
2. policy denial before observing an unapproved application;
3. approval with a fresh revision;
4. UI mutation while approval is pending;
5. an executor-detected stale revision race;
6. approval rejection;
7. approval expiry;
8. stale-generation rejection plus dominant emergency cancellation and a late
   action result;
9. executor failure with safe terminal events and redacted logs.

No real desktop API or Peekaboo process is used by these tests.

## Next step

Implement a supervised, pinned Peekaboo v3.9.10 MCP adapter for the executor
contract. Start with the reversible TextEdit fixture and the narrow tool
allowlist recorded in the computer-use research note. Measure permission setup,
warm/cold observation latency, per-action latency, cancellation, and repeated
reliability before adding the Realtime `use_computer` tool.
