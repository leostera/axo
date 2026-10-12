#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/axo-resident-setup-check.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
# Pure setup policy/private preferences and disposable AppKit controls only.
# Never invokes real service registration, another frontend, or synthetic OS input.
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library -D AXO_RESIDENT_FIXTURE \
  -I "$PRODUCTS" "$PRODUCTS/AxoProtocol.o" \
  "$ROOT/apple/AxoMacAxod/AxodAgentRegistrationRequest.swift" \
  "$ROOT/apple/AxoMacAxod/AxodOwnerAbsenceLease.swift" \
  "$ROOT/apple/AxoMacAxod/AxodServiceLifecycle.swift" \
  "$ROOT/apple/AxoMacAxod/AxodSetupPolicy.swift" \
  "$ROOT/apple/AxoMacAxod/AxodSetupPresentation.swift" \
  "$ROOT/apple/AxoMacAxod/AxodResidentPresentation.swift" \
  "$ROOT/apple/AxoMacAxod/AxodMenuBarController.swift" \
  "$ROOT/apple/AxoMacTests/ResidentSetupChecks.swift" \
  -o "$SCRATCH/check"
"$SCRATCH/check"
