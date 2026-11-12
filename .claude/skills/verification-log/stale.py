#!/usr/bin/env python3
"""Lists checks in docs/verification.md whose files changed after the commit they were
verified at. Usage: python3 .claude/skills/verification-log/stale.py [--all]

A check is current when no commit after its SHA touched its files. Uncommitted changes to
those files count too. --all prints current checks as well."""
import re
import subprocess
import sys
from pathlib import Path

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
log = (root / "docs/verification.md").read_text()
show_all = "--all" in sys.argv


def git(*args):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True).stdout.strip()


rows = []
for line in log.split("## Not verified yet")[0].splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) == 7 and re.fullmatch(r"[0-9a-f]{7,40}", cells[1]):
        rows.append(cells)

stale = 0
for date, sha, check, how, where, result, files in rows:
    paths = re.findall(r"`([^`]+)`", files)
    commits = git("log", "--format=%h %s", f"{sha}..HEAD", "--", *paths).splitlines()
    dirty = git("status", "--porcelain", "--", *paths).splitlines()
    if commits or dirty:
        stale += 1
        print(f"STALE  {sha}  {check}")
        for c in commits[:5]:
            print(f"         changed in {c}")
        if len(commits) > 5:
            print(f"         …and {len(commits) - 5} more commits")
        if dirty:
            print(f"         uncommitted changes: {', '.join(d[3:] for d in dirty)}")
    elif show_all:
        print(f"ok     {sha}  {check}")

print(f"\n{len(rows)} checks, {stale} stale.")
