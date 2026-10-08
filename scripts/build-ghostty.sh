#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION=7ec9e26a29399b30ef78f06985fc75045b3cecb6
if ! xcrun --find metal >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Full Xcode with its Metal toolchain is required. Select it using DEVELOPER_DIR or xcode-select.' >&2
  exit 1
fi
ZIG="${ZIG:-zig}"
if [[ "$($ZIG version)" != 0.16.0 ]]; then
  echo 'This Ghostty revision requires Zig 0.16.0. Set ZIG to that executable.' >&2
  exit 1
fi
mkdir -p "$ROOT/vendor"
if [[ ! -d "$ROOT/vendor/ghostty/.git" ]]; then
  git init "$ROOT/vendor/ghostty"
  git -C "$ROOT/vendor/ghostty" remote add origin https://github.com/ghostty-org/ghostty.git
fi
cd "$ROOT/vendor/ghostty"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Refusing to change a dirty Ghostty checkout.' >&2
  exit 1
fi
git fetch --depth 1 origin "$REVISION"
git checkout --detach "$REVISION"
"$ZIG" build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false
