#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-sidebar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -parse-as-library \
  "$ROOT/apple/AxoMacAxod/AxodSidebarPreferences.swift" \
  "$ROOT/apple/AxoMacTests/SidebarPreferencesChecks.swift" \
  -o "$TMP/check-sidebar"
"$TMP/check-sidebar"
xcrun swiftc -parse-as-library \
  "$ROOT/apple/AxoMacAxod/AxodCompactSidebarView.swift" \
  "$ROOT/apple/AxoMacTests/CompactSidebarChecks.swift" \
  -o "$TMP/check-compact-sidebar"
"$TMP/check-compact-sidebar"
xcrun swiftc -parse-as-library \
  "$ROOT/apple/AxoMacAxod/AxodSidebarSelection.swift" \
  "$ROOT/apple/AxoMacTests/SidebarSelectionChecks.swift" \
  -o "$TMP/check-sidebar-selection"
"$TMP/check-sidebar-selection"
