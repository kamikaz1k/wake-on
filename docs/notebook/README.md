# Wake On engineering notebook

This directory is the project's persistent engineering diary. Entries record
what we tried, what we observed, what failed, and what remains uncertain at the
time the work happened. They complement the architecture documents and ADRs:

- notebook entries preserve investigation history and provisional conclusions;
- architecture documents describe the current system;
- ADRs capture durable decisions and their rationale.

## Entries

| Date | Entry | Outcome |
| --- | --- | --- |
| 2026-08-03 | [Native macOS AEC and single-owner microphone capture](2026-08-03-native-macos-aec-and-microphone.md) | Native speaker/mic full duplex worked; duplicate capture hurt wake responsiveness; a single native stream fixed the identified contention and passed an initial repeat trial |
| 2026-08-04 | [Computer-task contract and deterministic worker](2026-08-04-computer-task-contract.md) | Provider-neutral planner/executor/task lifecycle implemented with policy gates, expiring approvals, stale-state protection, and dominant cancellation |
| 2026-08-09 | [Peekaboo MCP adapter: supervised process boundary](2026-08-09-peekaboo-mcp-adapter.md) | Pinned adapter, dual-framing MCP client, hard cancellation, and action mapping validated; live UI fixture awaits macOS permissions |
| 2026-08-10 | [Modular macOS computer-planner guidance](2026-08-10-macos-computer-prompt.md) | Peekaboo-informed macOS operating guidance adapted to WakeOn's action contract as selectable, provider-neutral prompt modules |
| 2026-08-10 | [Foreground-priority asynchronous computer tasks](2026-08-10-async-computer-voice-bridge.md) | Realtime tool calls now acknowledge immediately; background completion is queued behind voice activity and supports task-only cancellation |
| 2026-08-22 | [Thin Peekaboo MCP integration](2026-08-22-thin-peekaboo-mcp-integration.md) | Removed the custom action/planner/executor stack; live Peekaboo MCP schemas and calls now pass through unchanged behind the existing asynchronous voice seam |
| 2026-08-23 | [Interruptible computer subagent](2026-08-23-interruptible-computer-subagent.md) | Added goal revisions and voice-callable steering; stale plans cannot act after a revision, and MCP results are compacted before entering model context |
| 2026-08-23 | [Peekaboo computer-agent latency](2026-08-23-peekaboo-agent-latency.md) | Live Chrome task took about 24 seconds and $0.036; sequential model turns dominated, while a direct 22.87-second Peekaboo failure exposed a secondary slow path |

## Entry convention

Use `YYYY-MM-DD-short-topic.md`. Include:

- the question or problem;
- relevant starting state;
- experiments in chronological order;
- measurements and direct observations, separated from inference;
- failed approaches and unexpected behavior;
- decisions made during the investigation;
- unresolved questions and the next useful experiment.

Do not silently rewrite an old result to match newer knowledge. Add a dated
correction or a new entry and link the two.
