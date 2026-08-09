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
