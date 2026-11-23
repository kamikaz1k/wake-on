#!/bin/sh
# Memory simulation (see main.swift). Builds the app's Memory struct with a Mac driver.
#   run.sh <out-dir> [lobby|eager|never]
# BUDGET=12 SUMMARIZE_AT=8 squeezes the memory as 280 notes would at the app's 40 lines.
# COVER=fading uses OptMem's start-of-call rule (detail fades with age) instead of even.
# RAW_MAX=2 summarizes every block bigger than 2 notes from two summaries (before 2026-11-23).
# LEGACY=1 rebuilds the first version (8 notes per summary, long lines cut).
# Needs OPENAI_API_KEY, else reads OPENAI_PROJECT_API_KEY from server/.env (never printed).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"; policy="${2:-lobby}"
build="$(mktemp -d)"
block=2; raw=${RAW_MAX:-16}; [ "${LEGACY:-}" = 1 ] && block=8 && raw=8
# Everything before MemoryStore, without UIKit (the struct only needs Foundation).
sed -n '/^\/\/\/ The memory on this iPhone/q;p' "$here/../../WakeOn/Memory.swift" | grep -v "^import UIKit" | sed "s/static let noteBytes = 280/static let noteBytes = ${NOTE_BYTES:-280}/; s/static let block = 2/static let block = $block/; s/static let budget = 40/static let budget = ${BUDGET:-40}/; s/static let summarizeAt = 24/static let summarizeAt = ${SUMMARIZE_AT:-24}/; s/static let coverRule = CoverRule.even/static let coverRule = CoverRule.${COVER:-even}/; s/static let rawMax = 16/static let rawMax = $raw/" > "$build/Memory.swift"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -o "$build/sim" "$build/Memory.swift" "$here/main.swift" 2>&1 | grep -v warning || true
if [ -z "${OPENAI_API_KEY:-}" ]; then
  OPENAI_API_KEY="$(grep '^OPENAI_PROJECT_API_KEY=' "$here/../../../../server/.env" | cut -d= -f2- | sed "s/^'\(.*\)'$/\1/")"
  export OPENAI_API_KEY
fi
"$build/sim" "$here" "$out" "$policy"
