# Foreground-priority asynchronous computer tasks

- **Date:** 2026-08-10
- **Status:** implemented and covered by deterministic tests; live macOS trial pending permissions

## Problem

The first Realtime bridge ran the computer worker outside the WebSocket callback
thread, so microphone upload continued, but it kept the model's function call
unresolved until the complete multi-step Peekaboo task finished. Thread-level
asynchrony was not enough to guarantee a natural conversation during a task.

The product requirement is stronger: microphone streaming, server VAD,
barge-in, and new voice turns have priority over background computer work.
Individual computer actions should not receive artificial delays, but their
progress or completion must not speak over the user or an existing response.

## Decision

`use_computer` is now an asynchronous job boundary:

1. validate application scope;
2. start the existing `ComputerTaskWorker`;
3. immediately return `accepted` with a stable task ID;
4. drain worker progress and terminal events through `OpenAIRealtimeAgent.poll`;
5. keep progress in terminal logs;
6. queue terminal results until foreground voice is idle;
7. insert the result as a system conversation item and request one brief audio
   response.

The idle gate requires no active user speech, model response, or playback, plus
a 750 ms grace period after server VAD reports speech stopped. This grace closes
the race between `speech_stopped` and the server-created foreground response.

`cancel_computer_task` cancels the active task by ID without ending the voice
conversation. Conversation end and emergency stop still cancel the task and
suppress its late terminal callback. Task IDs are associated with the current
voice activation generation so results from an older conversation cannot enter
a newer one.

## Why not out-of-band audio

Out-of-band Realtime responses remain a possible text-only mechanism for
background classification or summarization. They are not used for user-facing
computer completion because parallel audio would require a second playback
arbiter and could speak over the foreground conversation. Completion instead
waits for the default conversation to become idle and is retained in that
conversation's context.

## Deterministic results

Tests confirm:

- task acceptance is returned before terminal completion;
- the one-task slot is released by a terminal worker event;
- microphone frames continue uploading while a task is active;
- completion does not emit during user speech or an active model response;
- task-only cancellation leaves the voice agent active;
- application and task IDs are checked before start or cancellation.

## Next experiment

After granting Screen Recording and Accessibility to the ChatGPT-hosted
process, run a bounded TextEdit task. While it is running, barge into the brief
acknowledgement, ask an unrelated question, cancel or replace the computer task,
and verify that no completion audio overlaps the foreground turn.
