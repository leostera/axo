#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-pane-layout.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" && -f "$PRODUCTS/AxoCore.o" ]] || { echo 'Build the Mac target before pane-layout checks.' >&2; exit 1; }
SOURCES=()
for name in AxodPaneLayouts AxodPaneLayoutPersistence AxodPaneLayoutLeaf AxodPaneSplitDirection AxodPaneFocusDirection AxodShellCreation AxodEmptyStartupPolicy; do
  SOURCES+=("$ROOT/apple/AxoMacAxod/$name.swift")
done
for name in SplitTree Array+Extension PointerBackport; do
  SOURCES+=("$ROOT/apple/AxoMac/Ghostty/$name.swift")
done
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" "${SOURCES[@]}" \
  "$ROOT/apple/AxoMacTests/PaneLayoutChecks.swift" "$PRODUCTS/AxoProtocol.o" "$PRODUCTS/AxoCore.o" \
  -framework AppKit -o "$TMP/check-pane-layout"
"$TMP/check-pane-layout"
