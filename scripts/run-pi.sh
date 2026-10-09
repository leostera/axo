#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export AXO_AUTO_TITLE="${AXO_AUTO_TITLE:-1}"
export AXO_CONFIG="${AXO_CONFIG:-$ROOT/local/relay.json}"
if [[ ! -f "$AXO_CONFIG" ]]; then unset AXO_CONFIG; fi
SESSION_FILE="$ROOT/local/playground/session.jsonl"
DIRECTORY="$ROOT/local/playground"
# Axo-owned launch arguments are removed before invoking the unchanged Pi CLI.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --axo-session-file) [[ $# -ge 2 ]] || exit 64; SESSION_FILE="$2"; shift 2 ;;
    --axo-directory) [[ $# -ge 2 ]] || exit 64; DIRECTORY="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "$DIRECTORY" == "$ROOT/local/playground" ]]; then mkdir -p "$DIRECTORY"; fi
[[ -d "$DIRECTORY" && -d "$(dirname "$SESSION_FILE")" ]] || { echo 'Axo launch directory unavailable; repair it before resuming.' >&2; exit 72; }
cd "$DIRECTORY"
exec node "$ROOT/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
  --session "$SESSION_FILE" \
  --extension "$ROOT/bridge/dist/extension.ts" "$@"
