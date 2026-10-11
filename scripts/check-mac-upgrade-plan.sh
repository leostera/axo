#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-upgrade-plan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
[[ -f "$PRODUCTS/AxoProtocol.o" ]] || { echo 'Build the Mac target before upgrade-plan checks.' >&2; exit 1; }
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -I "$PRODUCTS" \
  "$PRODUCTS/AxoProtocol.o" \
  "$ROOT/apple/AxoMacAxod/AxodDaemonUpgradePlan.swift" \
  "$ROOT/apple/AxoMacTests/DaemonUpgradePlanChecks.swift" \
  -o "$TMP/check-upgrade-plan"
"$TMP/check-upgrade-plan"
