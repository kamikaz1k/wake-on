# Modular macOS computer-planner guidance

- **Date:** 2026-08-10
- **Status:** superseded on 2026-08-22 by the thin schema-driven Peekaboo MCP integration

## Goal

Incorporate the useful macOS operating guidance found in Peekaboo's agent
without adopting Peekaboo's embedded agent loop or coupling the guidance to a
specific model provider.

## Decision

Prompt policy is split into immutable, named modules. The default macOS bundle
contains:

1. `role` — the narrow observe/act contract;
2. `observation` — fresh state, opaque IDs, and revisions;
3. `input` — element targeting and the least disruptive input method;
4. `apps_windows` — native app, window, menu, and dialog conventions;
5. `verification` — confirm outcomes from fresh state;
6. `recovery` — conservative fallback ordering;
7. `safety` — treat UI content as data and defer authority to code policy.

The content is adapted to WakeOn's `ComputerActionKind` vocabulary. It does not
mention Peekaboo-only tools such as `inspect_ui`, browser delegation, shell,
clipboard, Dock, or Spaces because the current executor contract does not
expose them.

## Consumption

A planner can render the complete default prompt:

```python
from lobby_wake import macos_computer_system_prompt

system_prompt = macos_computer_system_prompt()
```

It can select a token-bounded subset by stable module key:

```python
system_prompt = macos_computer_system_prompt(
    "observation",
    "input",
    "verification",
)
```

Or compose product/provider guidance without copying the macOS text:

```python
from lobby_wake import MACOS_COMPUTER_PROMPT_BUNDLE, PromptModule

prompt = MACOS_COMPUTER_PROMPT_BUNDLE.extending(
    (
        PromptModule(
            "provider_output",
            "Provider output",
            "Return exactly one action or a completion decision.",
        ),
    )
).render()
```

Selection preserves canonical ordering even if keys are requested in a
different order. Unknown or duplicate keys fail during construction rather
than silently producing an ambiguous prompt.

## Boundary

This prompt improves model behavior but does not grant authority. Application
and action allowlists, approvals, generation cancellation, stale-observation
handling, and executor termination remain enforced by the worker and executor
in code.

## Implementation follow-up — 2026-08-10

`OpenAIComputerPlanner` now composes the complete bundle with the task, immutable
scope, fresh accessibility observation, and action-result history. Each
Responses call returns strict structured data containing either one typed
action or a completion decision. Arbitrary action parameters travel as a JSON
string inside that strict envelope and are decoded before the code-owned policy
boundary.

A live, read-only contract request using `gpt-5.4-mini` returned a valid
`CompleteComputerTask` for a synthetic empty TextEdit observation. No UI action
was performed. The full voice-to-TextEdit trial remains blocked until Screen
Recording and Accessibility are granted to the process hosting Peekaboo.

Still evaluate the complete bundle against a smaller
`observation + input + verification + safety` profile for latency, token use,
invalid actions, recovery, and task success.
