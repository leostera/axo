#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AXO_REPO="$ROOT"
export GHOSTTY_RESOURCES_DIR="$ROOT/vendor/ghostty/zig-out/share/ghostty"
export TERMINFO="$ROOT/vendor/ghostty/zig-out/share/terminfo"
if [[ ! -d "$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework" ]]; then
  echo 'Run scripts/build-ghostty.sh first.' >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then rerun this script.' >&2; exit 1; }
npm --prefix "$ROOT" run build:bridge
(cd "$ROOT/apple" && xcodegen generate)
xcodebuild -project "$ROOT/apple/Axo.xcodeproj" -scheme AxoMac -configuration Debug \
  -derivedDataPath "$ROOT/apple/DerivedData" CODE_SIGNING_ALLOWED=NO build
exec "$ROOT/apple/DerivedData/Build/Products/Debug/AxoMac.app/Contents/MacOS/AxoMac"
