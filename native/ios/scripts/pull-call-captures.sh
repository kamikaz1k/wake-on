#!/bin/sh
# Copies Wake On's call captures (full Live API event logs, one .jsonl per chat log) and the
# chat logs themselves from the phone into native/ios/captures/ (git-ignored: these are real
# conversations). Usage: scripts/pull-call-captures.sh [device id or name]
set -eu
cd "$(dirname "$0")/.."
device="${1:-5976CF6D-0FD6-5A57-9711-AA29F94404E7}"
out=captures
mkdir -p "$out"
copy() {
  xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
    --domain-identifier dev.wakeon.ios --source "$1" --destination "$2" >/dev/null
}
copy "Library/Application Support/chat-logs.json" "$out/chat-logs.json" 2>/dev/null || echo "No chat logs on the phone yet."
if copy "Library/Application Support/call-captures" "$out/call-captures" 2>/dev/null; then
  echo "$(ls "$out/call-captures" | wc -l | tr -d ' ') captures in $out/call-captures"
else
  echo "No call captures on the phone yet: make a call with this build first."
fi
