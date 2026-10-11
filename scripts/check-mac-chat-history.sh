#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-chat-history.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" ]] || { echo 'Build the Mac target before history-window checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$ROOT/apple/AxoMacAxod/AxodChatHistoryWindow.swift" "$ROOT/apple/AxoMacTests/ChatHistoryWindowChecks.swift" \
  "$PRODUCTS/AxoProtocol.o" -framework Foundation -o "$TMP/check-chat-history"
"$TMP/check-chat-history"
