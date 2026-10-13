#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-pane-presentation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" ]] || { echo 'Build the Mac target before pane presentation checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$ROOT/apple/AxoMac/Ghostty/SplitTree.swift" "$ROOT/apple/AxoMac/Ghostty/Array+Extension.swift" \
  "$ROOT/apple/AxoMacAxod/AxodPaneLayouts.swift" "$ROOT/apple/AxoMacAxod/AxodPaneLayoutLeaf.swift" \
  "$ROOT/apple/AxoMacAxod/AxodPaneFocusDirection.swift" \
  "$ROOT/apple/AxoMacTests/CentralPanePresentationChecks.swift" "$PRODUCTS/AxoProtocol.o" \
  -framework AppKit -o "$TMP/check-pane-presentation"
"$TMP/check-pane-presentation"
