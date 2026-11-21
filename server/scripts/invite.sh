#!/bin/sh
# Invite codes. Run from server/.
#   scripts/invite.sh add "Alex"      makes a code for Alex and prints it (shown once)
#   scripts/invite.sh revoke CODE     turns a code off
# Only the code's SHA-256 is stored in KV.
set -eu
cd "$(dirname "$0")/.."
hash() { printf %s "$1" | shasum -a 256 | cut -d' ' -f1; }
case "${1:-}" in
  add)
    name="${2:?name}"
    code=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12 | sed 's/\(....\)\(....\)\(....\)/\1-\2-\3/')
    npx wrangler kv key put --binding USAGE --remote "code:$(hash "$code")" "{\"name\":\"$name\"}" >/dev/null
    echo "Invite code for $name: $code"
    ;;
  revoke)
    code="${2:?code}"
    npx wrangler kv key delete --binding USAGE --remote "code:$(hash "$code")"
    echo "Revoked."
    ;;
  *) echo "usage: scripts/invite.sh add NAME | revoke CODE"; exit 1 ;;
esac
