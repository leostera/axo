#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-native-workbench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
GHOSTTY="$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
HELPER="${AXO_LOCAL_DAEMON_BINARY:-$ROOT/axod/target/debug/axod}"
[[ -f "$PRODUCTS/AxoProtocol.o" && -f "$PRODUCTS/AxoCore.o" && -f "$PRODUCTS/AxoVoice.o" && -x "$HELPER" ]] || { echo 'Build the Mac target and helper before owned native workbench checks.' >&2; exit 1; }
SOURCES=()
for path in "$ROOT"/apple/AxoMacAxod/*.swift; do
  [[ "$(basename "$path")" == AxodWorkbenchApp.swift ]] || SOURCES+=("$path")
done
for name in WorkspaceSidebarRow WorkspaceWindowState MacSettingsView MacSettingsNavigation MacAppearance MacVoiceCoordinator MacVoiceHistoryStore MacVoiceKeyBinding MacVoiceKeyBindingRecorder GhosttyRuntime TerminalView; do
  SOURCES+=("$ROOT/apple/AxoMac/$name.swift")
done
for path in "$ROOT"/apple/AxoMac/Ghostty/*.swift; do
  [[ "$(basename "$path")" == Package.swift ]] || SOURCES+=("$path")
done
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -D AXO_NATIVE_FIXTURE -parse-as-library \
  -I "$PRODUCTS" -I "$GHOSTTY/Headers" "${SOURCES[@]}" \
  "$ROOT/apple/AxoMacTests/NativeWorkbenchFixtureChecks.swift" \
  "$PRODUCTS/AxoProtocol.o" "$PRODUCTS/AxoCore.o" "$PRODUCTS/AxoVoice.o" "$GHOSTTY/ghostty-internal.a" \
  -lc++ -framework AppKit -framework SwiftUI -framework Metal -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework IOSurface -framework Carbon -framework IOKit -framework ServiceManagement \
  -o "$TMP/native-workbench-check"
cargo build --manifest-path "$ROOT/axod/Cargo.toml" --locked --offline --example native-workbench-fixture
"$ROOT/axod/target/debug/examples/native-workbench-fixture" "$TMP/native-workbench-check" "$HELPER"
