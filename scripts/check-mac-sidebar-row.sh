#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/axo-sidebar-row.XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -framework AppKit \
  "$ROOT/apple/AxoMac/NativeAgentActivity.swift" \
  "$ROOT/apple/AxoMac/WorkspaceSidebarRow.swift" \
  "$ROOT/apple/AxoMacTests/SidebarRowChecks.swift" \
  -o "$CHECK/sidebar-row-checks"
"$CHECK/sidebar-row-checks"
