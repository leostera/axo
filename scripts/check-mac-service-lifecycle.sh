#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/axo-service-lifecycle-check.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
# Uses the compiled shared protocol from the sequential Mac build. Platform
# effects are fixture counters; these checks never register or stop a real service.
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library \
  -I "$PRODUCTS" "$PRODUCTS/AxoProtocol.o" \
  "$ROOT/apple/AxoMacAxod/AxodAgentRegistrationRequest.swift" \
  "$ROOT/apple/AxoMacAxod/AxodOwnerAbsenceLease.swift" \
  "$ROOT/apple/AxoMacAxod/AxodServiceLifecycle.swift" \
  "$ROOT/apple/AxoMacTests/ServiceLifecycleChecks.swift" \
  -o "$SCRATCH/check"
"$SCRATCH/check"
# Production service management has no agent-unregister or direct-launch seam.
if rg -q 'repairOwnerlessDaemonService|upgradeConnectedDaemon|startIfOwnerAbsent|SMAppService' "$ROOT/apple/AxoMacAxod/AxodWorkbenchCoordinator.swift"; then
  echo 'FAIL: workbench still owns a service mutation/launch path' >&2
  exit 1
fi
