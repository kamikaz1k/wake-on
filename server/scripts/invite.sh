#!/bin/sh
# Invite codes. Run from server/. See scripts/invite.mjs for the commands:
#   scripts/invite.sh add NAME | revoke NAME | keys new | keys retire ID | list
set -eu
cd "$(dirname "$0")/.."
exec node scripts/invite.mjs "$@"
