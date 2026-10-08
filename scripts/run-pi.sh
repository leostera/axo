#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export AXO_CONFIG="${AXO_CONFIG:-$ROOT/local/relay.json}"
if [[ ! -f "$AXO_CONFIG" ]]; then unset AXO_CONFIG; fi
mkdir -p "$ROOT/local/playground"
cd "$ROOT/local/playground"
exec node "$ROOT/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
  --session "$ROOT/local/playground/session.jsonl" \
  --extension "$ROOT/bridge/dist/extension.mjs" "$@"
