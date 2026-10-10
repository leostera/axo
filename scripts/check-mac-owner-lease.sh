#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-owner-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -parse-as-library \
  "$ROOT/apple/AxoMacAxod/AxodOwnerAbsenceLease.swift" \
  "$ROOT/apple/AxoMacTests/OwnerAbsenceLeaseChecks.swift" \
  -o "$TMP/check-owner-lease"
"$TMP/check-owner-lease"
