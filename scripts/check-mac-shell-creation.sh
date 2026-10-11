#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-shell-creation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" && -f "$PRODUCTS/AxoCore.o" ]] || { echo 'Build the Mac target before client-state checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$ROOT/apple/AxoMacAxod/AxodShellCreation.swift" "$ROOT/apple/AxoMacTests/ShellCreationChecks.swift" \
  "$PRODUCTS/AxoProtocol.o" "$PRODUCTS/AxoCore.o" -framework AppKit -o "$TMP/check-shell-creation"
"$TMP/check-shell-creation"
