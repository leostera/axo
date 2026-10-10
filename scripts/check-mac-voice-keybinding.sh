#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-voice-keybinding.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -parse-as-library \
  "$ROOT/apple/AxoMac/MacVoiceKeyBinding.swift" \
  "$ROOT/apple/AxoMac/MacVoiceKeyBindingRecorder.swift" \
  "$ROOT/apple/AxoMacTests/VoiceKeyBindingRecorderChecks.swift" \
  -o "$TMP/check-voice-keybinding"
"$TMP/check-voice-keybinding"
