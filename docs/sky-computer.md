# Sky computer-use prototype

Wake-on's `sky` target uses `@oai/sky` inside an authenticated Codex worker.
The existing ChatGPT login powers the computer worker; the Realtime voice
connection still uses wake-on's `OPENAI_API_KEY`. No credentials are copied out
of Codex, and an API key alone does not supply Sky's native host capabilities.

## Try it without voice

From this checkout:

```sh
uv run python -m lobby_wake.sky_cli doctor
uv run python -m lobby_wake.sky_cli run \
  'Use sky.list_apps() once and report whether Finder is listed. Change nothing.' \
  --app Finder --timeout 90 --log /tmp/wake-on-sky.jsonl
```

`doctor` selects the latest dated capture in `~/workspace/sky-lib-archive`, checks
its package metadata, and executes only `list_apps`. Supply `--archive PATH` for
another archive and `--node PATH` for another Node executable. It returns exit
code 1 when direct SDK access is unavailable; this is the expected result on the
currently tested macOS setup. It does not verify the archive's content hashes;
use the archive repository's `make verify` for that.

`run` uses the installed host's Sky runtime, not the archived binaries. It returns
JSON and exit code 0 for worker-reported completion, 1 for failure or timeout,
and 130 for Ctrl-C. Use `--codex-command` or `--model` to select a different
Codex executable or model. The default model is the existing Sky target's
`gpt-5.6-luna`. Codex must already be signed in and have the computer-use runtime
and macOS app permissions available. Its normal state directory and network
access must be writable/reachable; an outer sandbox can prevent startup.

## Select it for voice

Add these options to the existing process-delegate launch:

```sh
python -m lobby_wake.openai_process_delegate \
  --computer-use --computer-backend sky \
  --computer-allow-app Finder --sky-timeout 180
```

When launching through `lobby-wake`, pass them after the existing
`--delegate-command python -m lobby_wake.openai_process_delegate` command.
Repeat `--computer-allow-app` to permit other apps. The runner rejects task
requests for apps outside this list; within the worker, the app scope is a prompt
constraint plus the host's own computer-use permissions, not a separate sandbox.

Tasks run asynchronously, support cancellation and steering, and have a total
wall-clock deadline (including steered turns). Cancellation sends SIGTERM to the
worker process group, with SIGKILL after two seconds if needed. Steering resumes
the same Codex session when its ID is available. Terminal success requires a
structured completion result; missing runtime, failed turns, and prose-only
responses fail closed. This is a model-reported outcome, not an independent
semantic verifier of arbitrary UI tasks.

## What the archive established

Inspected capture: October 8, 2026, Sky **0.6.32**, payload
`bb55e8b41315346afe616e351576916d98949c866e0d2fcb8eff1a16ed23f992`.

The package exposes app state, accessibility actions, clicks, typing, keypresses,
scrolling, dragging, and other platform-specific operations. On macOS,
`targets/mac/native-pipe.js` requires the trusted `nodeRepl` runtime and its
native pipe capability. `sky.js` proxies calls through that host's Sky RPC
service. A standalone Node import loads, but `list_apps()` fails with:

```text
Sky Computer Use requires the trusted nodeRepl runtime
```

Changing model billing from subscription to API-key authentication cannot create
that native capability. A standalone archive-backed macOS executor would need an
OpenAI-provided host/transport integration. The prototype does not patch native
binaries, impersonate the host, or relax native authentication.

Official [Sign in with ChatGPT documentation](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)
describes plan-backed model access for eligible integrations; it does not establish
standalone access to the archived Sky native service. This prototype reuses the
working Codex login rather than implementing a new sign-in flow.

## Verification, October 11, 2026

The live read-only task imported `@oai/sky` through `mcp__node_repl__js`, called
`sky.list_apps()`, and reported **Finder is listed**. The recorded tool call was
checked, not just the worker's final sentence. The test used the installed SDK;
the archive was tested separately with `doctor`.

- Elapsed time: approximately 17 seconds.
- Input tokens: 112,498; cached: 99,840; uncached: 12,658.
- Output tokens: 843.
- No clicks, typing, app launches, or changes requested.

This verifies the SDK/host path, not full voice-to-UI latency or mutation flows.
The inherited Codex profile is context-heavy and starts unrelated configured MCP
servers. A smaller host profile needs its own validation before replacing the
working profile. There is no reliable dollar ceiling on this subscription path;
`--computer-max-task-cost-usd` applies to the API-backed computer runner, not Sky.
Keep Sky experimental until a voice task and a bounded UI action are benchmarked.
