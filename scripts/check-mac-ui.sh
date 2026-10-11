#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Rust owns the disposable state/model peer. XCTest drives the actual signed
# dist bundle through public XCUIAutomation, not a separate terminal test host.
# The runner refuses to launch while any normal Axo frontend is running.
export AXO_APP_SELF_TEST_CASE=ui
bash "$ROOT/scripts/check-mac-app-startup.sh"
