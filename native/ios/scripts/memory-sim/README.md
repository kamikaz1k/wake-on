# Memory simulation

Fills Lobby's memory with three months of made-up calls (`persona.txt`: 70 calls, 83 notes,
with a move, a job change and a cancelled trip) using the app's own `Memory` struct, writes the
summaries with real `gpt-5.4-mini` requests, and quizzes a model on `quiz.txt` at days 30, 60
and 89. Each quiz is asked twice: from the start-of-call memory alone, and with the `recall` tool.

```sh
native/ios/scripts/memory-sim/run.sh <out-dir> [lobby|eager|never]
```

- `lobby` is the app's policy, `eager` summarizes after every call that saved a note, and
  `never` writes no summaries.
- Settings: `SUMMARY_MODEL` and `SUMMARY_EFFORT` (default: the app's), `QUIZ_MODEL` (default `gpt-5.6-terra`, the model calls use), `GRADE_MODEL` (default `gpt-6.1-terra`), `BUDGET=12 SUMMARIZE_AT=8` (squeezes the memory as about 280 notes would at the app's 40 lines), and `LEGACY=1` (the first version: 8 notes per summary, long lines cut).
- `quiz.txt` has 35 questions; prices are in `main.swift`.
- The key comes from `OPENAI_API_KEY`, else from `server/.env`. It is never printed.
- Each run writes `report.md`, `calls.tsv` (one row per call), `summaries.txt`, the
  start-of-call text at each checkpoint, and `memory.json`.
- To load a run's `memory.json` onto the phone (back up the phone's own first), use
  `devicectl device copy to` with `Library/Application Support/memory.json`, then launch with
  `--memory-summarize`.

## Findings (2026-11-22)

**Round 1, the first version.** Summaries merged 8 notes, and lines over 280 bytes were cut. The
model wrote 257–505 bytes, so 12 of 15 summaries were cut and their facts lost. Replies were
sometimes empty with low reasoning and a 400-token cap.

**Round 2, after OptMem.** Summaries now merge two lines at a time. A line that's too long is
sent back with "Too long: N bytes", and the model writes it again. The output cap is 2,000
tokens. But the call still started with the oldest 16 notes squeezed into one line, so early
details were lost whichever model wrote it.

**Round 3, the cover rule.** The call-start memory now opens the summary that covers the most
notes first, so lines stay even. At 40 lines, all 83 notes then fit almost unsquashed, and
every model scored 35/35 from memory alone. To tell the models apart, the memory was cut to
12 lines (two runs each, out of 35):

| summary model | memory alone | with recall | retries for length | still too long after 3 | cost per 100 notes |
|---|---|---|---|---|---|
| gpt-6-luna, low | 23, 27 | 34, 34 | many | 1, 6 | $0.01 |
| gpt-6.1-terra, low | 27, 26 | 34, 33 | 8, 6 | 0, 1 | $0.05 |
| gpt-5.4-mini, low | 30, 26 | 35, 31 | 25, 20 | 4, 4 | $0.11 |
| gpt-6.2-sol, low | 28, 28 | 33, 34 | 1, 3 | 0, 0 | $0.07 |
| **gpt-6.2-sol, medium** | **31, 31** | 35, 33 | 2, 0 | 0, 0 | **$0.10** |
| gpt-6.2-astra, low | 32, 30 | 35, 35 | 10, 7 | 1, 0 | $0.35 |
| gpt-6.2-astra, medium | 32, 30 | 35, 35 | 10, 24 | 0, 5 | $0.51 |

- **Chosen: gpt-6.2-sol at medium reasoning.** It matched astra's score at about a quarter of
  the cost. It kept to the length limit best of all the models (2 retries in 150 summaries), and
  no summary failed.
- **Cost is small for any model.** About one summary per note, roughly $0.10 per 100 notes with sol.
- **Recall covers most gaps:** 33–35 out of 35 with every model. The summaries matter most for
  what Lobby knows without searching.
- **Quiz noise:** scores move by about ±2 between runs.
