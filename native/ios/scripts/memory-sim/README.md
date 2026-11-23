# Memory simulation

Fills Lobby's memory with three months of made-up calls (`persona.txt`: 70 calls, 83 notes,
with a move, a job change and a cancelled trip) using the app's own `Memory` struct, writes the
summaries with real OpenAI requests (`gpt-6.2-sol` by default), and quizzes a model on `quiz.txt` at days 30, 60
and 89. Each quiz is asked twice: from the start-of-call memory alone, and with the `recall` tool.

```sh
native/ios/scripts/memory-sim/run.sh <out-dir> [lobby|eager|never]
```

- `lobby` is the app's policy, `eager` summarizes after every call that saved a note, and
  `never` writes no summaries.
- Settings: `SUMMARY_MODEL` and `SUMMARY_EFFORT` (default: the app's), `QUIZ_MODEL` (default `gpt-5.6-terra`, the model calls use), `GRADE_MODEL` (default `gpt-6.1-terra`), `DATA` (a folder with another `persona.txt` and `quiz.txt`), `START` (day 0's date), `CHECKPOINTS` (quiz days, e.g. `11,22,33`), `TOOLS` (`recall`, or `recall,zoom`), `RAW_MAX` (blocks up to this many notes are summarized from the notes; default 16 as in OptMem, `RAW_MAX=2` for the earlier way), `COVER=fading` (OptMem's start-of-call rule, see below; default `even`), `BUDGET=12 SUMMARIZE_AT=8` (squeezes the memory as about 280 notes would at the app's 40 lines), and `LEGACY=1` (the first version: 8 notes per summary, long lines cut).
- `quiz.txt` has 35 questions; prices are in `main.swift`.
- The key comes from `OPENAI_API_KEY`, else from `server/.env`. It is never printed.
- Each run writes `report.md`, `calls.tsv` (one row per call), `summaries.txt`, the
  start-of-call text at each checkpoint, `memory.json`, and `result.json` (every question's
  grade, and each checkpoint's lines as days old and notes covered).
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

**Round 4, OptMem's own rule (2026-11-23).** OptMem doesn't keep lines even: a line may cover
more notes the older they are (`fading`), so detail fades with age, and the newest notes stay
word for word. Notes per line at day 89, oldest first, and quiz results (two runs each, sol medium):

| budget | rule | notes per line | memory alone | with recall |
|---|---|---|---|---|
| 40 | even | 4 ×8, 2 ×19, 1 ×13 | 35, 35 | 35, 35 |
| 40 | fading | 4 ×11, 2 ×10, 1 ×19 | 35, 35 | 35, 35 |
| 12 | even | 16, 16, 16, 16, 8, 4, 2, 1 ×5 | 30, 31 | 35, 35 |
| 12 | fading | 32, 16, 8, 8, 8, 4, 2, 1 ×5 | 30, 30 | 33, 34 |

- Same scores, different losses. Squeezed, fading forgot the oldest facts said once and never
  again (sister's birthday, weekday wake time, half the anniversary: the first 12 days, all in
  one 32-note line) and remembered more from the middle (moving company, landlord deal,
  dentist), which even forgot.
- Facts that changed later (city, job, drink, trip, vet) were right with both rules: the newer
  note is recent and wins.
- Fading is what we want (old things that don't come up again fade, recent ones stay sharp), so
  it's only as good as the refreshing: Lobby saving a fact again when it comes up again.

**Round 5, small blocks from the notes (2026-11-23).** OptMem writes blocks of up to 16 notes from
the notes themselves (`RAW_MAX`); Lobby wrote every block above 2 from two summaries, so a fact
one summary dropped was gone from every summary above it. At 12 lines, three runs each, memory
alone out of 35 (sol medium):

| rule | from two summaries | up to 16 notes from the notes |
|---|---|---|
| even | 30, 31, 29 | **33, 33, 32** |
| fading | 30, 30, 30 | 30, 31, 29 |

- Even gains because its squeezed lines are 16-note blocks, now written from all 16 notes.
  Fading's oldest line covers 32 notes, still merged from two summaries, and that's where it
  loses the sister's birthday, wake time and playlist either way.
- Example, the Oct 15–20 line. From two summaries: "…Grace is Sam's mom…" (one half had already
  dropped the visit). From the notes: "…Sam's mom Grace is visiting Montreal for Christmas,
  Dec 22–28, 2026…". The mom's visit went from 0 of 6 to 6 of 6 runs right, with both rules.
- At 40 lines, still 35/35 with both rules. Cost about 10% more ($0.08–0.11 per run).
- Time to first reply (gpt-5.6-terra, low, 8 calls each, nothing cached): 40 full-length lines,
  3.9k tokens, 624 ms median; 96 lines (OptMem's default), 9.4k tokens, 768 ms. Kept at 40.

**Round 6, a real history (2026-11-23).** The Wake On development thread itself (Oct 21 to Nov 23,
383 exchanges): gpt-5.6-terra (low) took notes on each exchange with OptMem's note rule, seeing its
last 40 notes so it skips repeats (414 notes, $2.61); sol wrote 61 questions from the notes (27
detail, 17 changed later, 8 recent, 7 recurring, 2 early). The data stays out of the repo. Replayed at
the app's real 40 lines, sol medium summaries, quiz on day 33, two runs each, out of 61:

| rule | memory alone | with recall | with recall and zoom |
|---|---|---|---|
| even | 37, 34, 39, 38 | 38, 35 | **43, 42** |
| fading | 29, 31, 27, 27 | 35, 31 | 34, 31 |

By age, right answers from memory alone summed over the four runs (oldest third of the timeline,
middle, newest): even 30, 48, 70 of 80, 80, 84; fading 13, 32, 69.

- Fading didn't buy recency here: the newest third came out the same (70 against 69), because 40
  lines already hold the newest notes word for word either way. It only lost the older two thirds,
  recurring facts included (20 against 15 of 28).
- Zoom helped with even (+6) and not with fading, whose old lines cover 32 to 64 notes: two levels
  of zooming don't get back to a fact.
- 414 notes made 393 summaries for $0.72 to $0.79 a run ($0.18 per 100 notes), with 51 to 82 retries
  for length and 0 to 3 still too long.
