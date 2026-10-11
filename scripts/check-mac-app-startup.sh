#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${AXO_APP_UNDER_TEST:-$PWD/dist/Axo.app}"
codesign --verify --deep --strict "$app"
# LaunchServices opens the signed bundle, not a Swift test host.
# The app opens a visible regular window and handles its own NSEvents. No AX grant
# is required. ServiceManagement/live-user handoff is deliberately not exercised.
cargo run --manifest-path axod/Cargo.toml --locked --offline \
  --example app-startup-fixture -- "$app"
