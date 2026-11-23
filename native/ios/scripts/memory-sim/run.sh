#!/bin/sh
# Memory simulation (see main.swift). Builds the app's Memory struct with a Mac driver.
#   run.sh <out-dir> [lobby|eager|never]
# Needs OPENAI_API_KEY, else reads OPENAI_PROJECT_API_KEY from server/.env (never printed).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"; policy="${2:-lobby}"
build="$(mktemp -d)"
# Everything before MemoryStore, without UIKit (the struct only needs Foundation).
sed -n '/^\/\/\/ The memory on this iPhone/q;p' "$here/../../WakeOn/Memory.swift" | grep -v "^import UIKit" | sed "s/static let noteBytes = 280/static let noteBytes = ${NOTE_BYTES:-280}/" > "$build/Memory.swift"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -o "$build/sim" "$build/Memory.swift" "$here/main.swift" 2>&1 | grep -v warning || true
if [ -z "${OPENAI_API_KEY:-}" ]; then
  OPENAI_API_KEY="$(grep '^OPENAI_PROJECT_API_KEY=' "$here/../../../../server/.env" | cut -d= -f2- | sed "s/^'\(.*\)'$/\1/")"
  export OPENAI_API_KEY
fi
"$build/sim" "$here" "$out" "$policy"
