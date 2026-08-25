# macOS Harness live voice trial: latency, permission recovery, and continuity

- **Date:** 2026-08-24
- **Status:** end-to-end path works; three product-level gaps reproduced
- **Log:** `latency.jsonl`

## Trial result

The native-AEC voice listener successfully delegated two Google Chrome tasks to
the macOS Harness backend while Realtime voice remained responsive. The user
observed useful browser actions, but the experience was still slow and did not
preserve browser continuity across requests.

## Measured timeline

### Task 1 — open Google in a new window

- Task ID: `0eb455f60b8c4d838f02c398e0f2fd3a`
- Started: wall time `1787621717.926729`
- Finished: wall time `1787621736.258355`
- Total task duration: **18.33 seconds**
- Responses turns: **7**
- macOS Harness executions: **6**
- First four executions returned `tool_error=true`; the final two succeeded.
- The ten-second slow-task reassurance fired as designed.
- Usage: **6,029 input tokens**, **597 output tokens**, **$0.007208 estimated**.
- Terminal summary: `Opened google.com in a new Chrome window.`

The new single-tool schema dramatically reduced cost relative to the Peekaboo
trial, but did not by itself reduce the number of sequential planning turns.
Repeated failed Python bursts dominated this task.

### Task 2 — search for “how to make rajma”

- Task ID: `8b348126dcd147918d749c33601c362b`
- Started: wall time `1787621746.021052`
- Finished: wall time `1787621752.718186`
- Total task duration: **6.70 seconds**
- Responses turns: **2**
- macOS Harness executions: **1**, lasting about **3.07 seconds**.
- Usage: **6,072 input tokens**, **405 output tokens**, **$0.006377 estimated**.
- The second Responses input grew to 5,615 tokens after the visual result was
  attached.

The task reported that the query was entered but Chrome's `Allow remote
debugging` prompt blocked further control. Despite that unresolved prerequisite,
the task was emitted as `status="completed"` and became terminal.

## Findings

### 1. Permission recovery has no acknowledgement/resume protocol

After the user accepted the Chrome permission prompt, no new
`computer.task_started`, steering event, or retry appears in the log. The voice
agent only repeated that it lacked confirmation that control had been restored.

This follows from the current lifecycle: the worker converted the blocked state
into a successful terminal completion. By the time the user supplied the
acknowledgement, there was no active task to steer and no pending prerequisite
to satisfy. The system currently understands only terminal completion/failure,
not `waiting_for_user`, `resume`, or `retry_after_acknowledgement`.

### 2. Continuity is reset between computer tasks

The search request created generation 2 with a new task ID rather than
continuing generation 1. Each task starts a fresh Responses input list containing
only the new goal and target application. It receives no previous task summary,
window/tab identity, Browser Harness session identity, or continuation token.

The user visually observed that task 1 opened Google in one Chrome instance and
task 2 operated another. The logs establish the missing task-level continuity,
but they cannot prove exactly which Chrome PID, window, tab, Browser Harness
daemon name, or generated Python operation caused the instance switch because
those fields are not currently logged.

Each `run_macos_harness` call also starts a fresh Python process. Browser Harness
may retain external daemon state, but WakeOn does not explicitly name or carry a
browser session between calls or tasks.

### 3. “One program per decision point” is not yet reliably happening

The integration exposes only one model tool, but task 1 still required six
program executions and seven remote model turns. Four executions failed before
the planner found a working route. The tool-surface reduction therefore solved
schema overhead, not planning latency or first-attempt correctness.

### 4. Current diagnostics are insufficient for browser continuity

The lifecycle logs intentionally omit generated code, tool stdout, screen
contents, and action parameters. That is good for ordinary privacy, but it means
this trial cannot answer:

- which browser helper or native method the planner selected;
- whether it used `new_tab`, `goto_url`, AppleScript, `open -na`, or another
  process-launching path;
- which Chrome PID/window/tab was targeted;
- whether successive calls connected to the same Browser Harness daemon.

A future diagnostic mode should record safe structural metadata such as
operation duration, operation outcome/error class, browser session name, Chrome
PID, window ID, target ID, and whether the operation created or reused a browser
context—without logging page content or generated code by default.

## Follow-up candidates

1. Add a nonterminal `waiting_for_user` result carrying an acknowledgement
   condition and resumable task ID.
2. Persist a small computer-session state across tasks: last application,
   browser session name, Chrome PID/window ID, target ID, and last successful
   summary.
3. Treat follow-up requests in the same application as continuations unless the
   user explicitly asks for a fresh window/session.
4. Add safe structural browser diagnostics before changing behavior.
5. Inspect the four failed first-task executions before optimizing general
   latency; the log currently records only `tool_error=true`.

No implementation change was made from this trial review. These are recorded
findings for the next design discussion.
