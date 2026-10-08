#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/apple/AxoCore"
swiftc "$ROOT/apple/AxoCore/Sources/AxoCore/Protocol.swift" "$ROOT/tests/swift-smoke.swift" -o "$TEMP/protocol-tests"
"$TEMP/protocol-tests"
# Type-check against the exact upstream C API without pretending to link/run it.
mkdir -p "$TEMP/GhosttyKit"
curl -fsSL https://raw.githubusercontent.com/ghostty-org/ghostty/7ec9e26a29399b30ef78f06985fc75045b3cecb6/include/ghostty.h -o "$TEMP/GhosttyKit/ghostty.h"
printf 'module GhosttyKit { header "ghostty.h" export * }\n' > "$TEMP/GhosttyKit/module.modulemap"
swiftc -typecheck -swift-version 5 -I "$TEMP/GhosttyKit" "$ROOT"/apple/AxoMac/*.swift
echo 'Mac sources type-check against pinned Ghostty headers; linking and UI tests still require Xcode.'
