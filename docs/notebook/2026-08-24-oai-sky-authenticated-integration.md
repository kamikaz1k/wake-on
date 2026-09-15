# OAI Sky integration: authenticated host boundary and Codex worker cost

- **Date:** 2026-08-24
- **Status:** authenticated Codex bridge implemented; voice E2E trial pending
- **Question:** can Wake On use the bundled `@oai/sky` computer-use API directly?

## Starting point

The installed Computer Use plugin documents a persistent Node REPL integration
with `@oai/sky`. Sky has a compact accessibility-oriented API: list apps,
observe app state, click, set/select/type text, press keys, scroll, drag, and
invoke an exposed secondary accessibility action. This looked like a good fit
for batching several deterministic UI actions into one model turn.

## Experiments

### Direct bundled Node REPL

Wake On successfully started ChatGPT's bundled `node_repl`, added the bundled
module directory, and imported `@oai/sky`. The first real `sky.list_apps()` call
failed with:

```text
Sky Computer Use native pipe startup failed
```

Repeating the trial with the exact Node REPL environment from Codex's local
configuration produced the same result. Module loading is therefore not the
blocked layer.

### Signed Computer Use MCP client

The signed `SkyComputerUseClient mcp` process initialized and returned its ten
tool schemas. Its first read-only `list_apps` operation failed with:

```text
Computer Use server error -10000: Sender process is not authenticated
```

This establishes that the native service authenticates the calling host. The
MCP executable alone is not a supported capability token for arbitrary local
processes.

### Trusted Codex worker

An ephemeral `codex exec` worker using the installed Computer Use skill made the
same read-only `sky.list_apps()` call successfully. It returned the available
apps in about 32 seconds. Usage for this trivial task was:

- input: **103,915 tokens**;
- cached input: **79,872 tokens**;
- uncached input: **24,043 tokens**;
- output: **384 tokens**.

A reduced `--ignore-user-config` profile cut total input to 28,833 tokens, but
the Node REPL tool was not made available to the agent. Enabling only the
Computer Use plugin in that profile still failed and consumed 86,893 input
tokens. We did not continue spending requests trying to reverse-engineer a
smaller trusted host profile.

## Implemented boundary

`CodexSkyTaskRunner` now implements the same asynchronous control shape consumed
by Realtime voice:

```text
prepare
start(task, application) -> accepted(task_id)
poll_events -> completed | failed | cancelled
cancel(task_id)
steer(task_id, revised_goal)
close
```

The runner starts a trusted Codex child and asks it to use only the installed
Computer Use skill and `@oai/sky`. Wake On immediately returns the task ID to
Realtime, so microphone streaming and barge-in remain independent. Cancellation
terminates the Codex process group. Steering terminates the current turn and
uses `codex exec resume` with the same Codex task ID, preserving UI/task context
while replacing the goal.

Codex JSONL usage is logged per task and cumulatively as input, cached input,
uncached input, and output tokens. Unlike the direct Responses worker, this path
does not yet have a reliable dollar estimate because it uses the authenticated
Codex product boundary rather than Wake On's API key.

## Conclusions

1. Direct Sky integration is intentionally unavailable to an ordinary local
   library process; the failure is sender authentication, not missing AX or
   Screen Recording permission.
2. The smallest verified supported integration is a supervised trusted Codex
   worker.
3. That worker is functional but currently extremely context-heavy for a voice
   assistant handoff. It is an experimental comparison backend, not the default.
4. The next useful measurement is a real voice task that records wake-to-task
   acceptance, acceptance-to-first-visible-action, total completion latency,
   and Codex token usage. Further hardening should wait for that result.
