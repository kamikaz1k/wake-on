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
- To try another prompt, set `SUMMARY_PROMPT=<file>`. To try another cut-off, set `NOTE_BYTES=400`.
- The key comes from `OPENAI_API_KEY`, else from `server/.env`. It is never printed.
- Each run writes `report.md`, `calls.tsv` (one row per call), `summaries.txt`, the
  start-of-call text at each checkpoint, and `memory.json`.
- To load a run's `memory.json` onto the phone (back up the phone's own first), use
  `devicectl device copy to` with `Library/Application Support/memory.json`, then launch with
  `--memory-summarize`.

## Findings (2026-11-22)

| policy | summary requests | tokens | day 89, memory alone | day 89, with recall |
|---|---|---|---|---|
| lobby | 15 | 6.6k | 18/20 | 20/20 |
| eager | 19 | 8.8k | 16/20 | 18/20 |
| never | 0 | 0 | 6–13/20 | 12–18/20 |

- **The app's policy works.** The summary job ran overnight 3 times (days 18, 45, 75) and never
  had to run right after a call. The start-of-call memory stayed at 40 lines or fewer (about
  4,200 characters). Running after every call cost about 30% more and scored no better.
- **Summaries are cut mid-word.** The model ignores the 280-character limit and writes 257–505
  bytes. 12 of 15 summaries were cut, and 15 of 17 on the phone. What gets cut is lost: "Ella's
  birthday", the brother's city, and a broken "starting O. Mo" that higher summaries then copied.
  A prompt asking for 40 words still gave 10 of 15 over the limit.
- **Replies sometimes come back empty:** 2 of about 17 summary requests in one run. With low
  reasoning effort, the 400-token output cap can leave no text. On the phone, the server answered
  502 for one of these and the job stopped; asking again worked 3 times out of 3.
- **Scores move by ±3 between runs** from grading noise alone. Read the gaps between policies,
  not single numbers.
- **Recall:** asked one question at a time, the model searches when memory lacks the answer.
  Asked a batch with a JSON reply format, it never searched.
