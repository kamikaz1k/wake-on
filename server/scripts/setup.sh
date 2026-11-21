#!/bin/sh
# One-time setup of the Cloudflare Worker. Run from server/: scripts/setup.sh
# Asks you to log in to Cloudflare in the browser and to paste the OpenAI key (it goes
# straight to Cloudflare's encrypted secrets, never to a file).
set -eu
cd "$(dirname "$0")/.."
npm install --silent
npx wrangler whoami >/dev/null 2>&1 || npx wrangler login
if grep -q REPLACE_WITH_KV_ID wrangler.toml; then
  id=$(npx wrangler kv namespace create USAGE 2>&1 | sed -n 's/.*id = "\([0-9a-f]*\)".*/\1/p' | head -1)
  [ -n "$id" ] || { echo "Couldn't create the KV namespace; run: npx wrangler kv namespace create USAGE"; exit 1; }
  sed -i '' "s/REPLACE_WITH_KV_ID/$id/" wrangler.toml
  echo "KV namespace: $id"
fi
echo "Paste the OpenAI project key when asked (it isn't shown or saved locally):"
npx wrangler secret put OPENAI_API_KEY
npx wrangler deploy
echo "Done. Put the workers.dev URL above into LobbyServer.url in native/ios/WakeOn/LobbyServer.swift."
