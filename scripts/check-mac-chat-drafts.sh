#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-chat-drafts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" ]] || { echo 'Build the Mac target before draft-state checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$ROOT/apple/AxoMacAxod/AxodChatDrafts.swift" "$ROOT/apple/AxoMacAxod/AxodPiMutationRequest.swift" \
  "$ROOT/apple/AxoMacTests/ChatDraftChecks.swift" \
  "$PRODUCTS/AxoProtocol.o" -framework AppKit -o "$TMP/check-chat-drafts"
"$TMP/check-chat-drafts"
