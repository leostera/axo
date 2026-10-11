#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-draft-persistence.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" ]] || { echo 'Build the Mac target before draft-persistence checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -D AXO_DRAFT_PERSISTENCE_FIXTURE -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$ROOT/apple/AxoMacAxod/AxodChatDrafts.swift" "$ROOT/apple/AxoMacAxod/AxodChatDraftArchive.swift" \
  "$ROOT/apple/AxoMacAxod/AxodChatDraftStore.swift" "$ROOT/apple/AxoMacAxod/AxodDraftPersistence.swift" \
  "$ROOT/apple/AxoMacTests/DraftPersistenceChecks.swift" \
  "$PRODUCTS/AxoProtocol.o" -framework AppKit -o "$TMP/check-draft-persistence"
"$TMP/check-draft-persistence"
