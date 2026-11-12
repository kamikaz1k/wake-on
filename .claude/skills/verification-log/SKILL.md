---
name: verification-log
description: Keep docs/verification.md, the record of what has been checked in Wake On, how, where (simulator or phone, iOS version) and at which commit SHA, and find checks that went stale because their files changed. Use after verifying anything (tests, screenshots, phone runs, measurements, the user confirming something works), before saying a feature works or is verified, and when asked what is or isn't verified.
---

# Verification log

`docs/verification.md` holds one row per check: date, SHA, what was checked, how, where,
the result (with numbers when there are any) and the files it covers. A check is only
as fresh as its files: once they change after its SHA, the row is history, not proof.

## After verifying something

Add a row at the top of the Checks table, newest first.

- **SHA**: the commit that was tested (`git rev-parse --short HEAD`). Verify committed code. If
  you tested uncommitted changes, commit first, then log that commit's SHA.
- **Check**: the behaviour, in the user's words ("Chat log page shows tool rows"), not the
  test name.
- **How**: unit test, UI test, simulator screenshot, phone (by Claude or by you), Instruments
  trace, or a script. Name the test class or tool.
- **Where**: phone or sim, as defined at the top of the file. Note other devices or iOS versions.
- **Result**: what you saw. Include numbers for measurements, and say what was not looked at
  ("installed, not opened on the phone").
- **Files**: the files or folders whose changes would make the check stale. Pick the code
  that produces the behaviour, not every file the commit touched.

When the user tells you something works (or doesn't), log it with How = "phone, by you".
Redoing a check adds a new row; never edit an old row's result to match newer knowledge.
Something important that is not verified goes in "Not verified yet" with the reason; remove
it from there when a check covers it.

## Before saying something works

```sh
python3 .claude/skills/verification-log/stale.py        # stale checks only
python3 .claude/skills/verification-log/stale.py --all  # every check
```

If the check you'd rely on is stale, rerun it (and log it) or say plainly that it was last
verified at that SHA and the files have changed since. A passing unit test suite doesn't
cover a UI or phone check.

## Commit

`docs/verification.md` and this skill are tracked: commit them with the work they record,
or on their own right after.
