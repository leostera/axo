#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-central-workbench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
GHOSTTY="$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
FIXTURE="$ROOT/axod/target/debug/examples/central-client-fixture"
HELPER="$ROOT/axod/target/debug/axod"
[[ -f "$PRODUCTS/AxoCore.o" && -f "$PRODUCTS/AxoVoice.o" && -x "$FIXTURE" && -x "$HELPER" ]] || { echo 'Build the Mac target and owned central fixture/helper first.' >&2; exit 1; }
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(find "$ROOT/apple/AxoMacAxod" -maxdepth 1 -name '*.swift' ! -name AxodWorkbenchApp.swift | sort)
for name in WorkspaceSidebarRow NativeAgentActivity WorkspaceWindowState MacSettingsView MacSettingsNavigation MacAppearance MacVoiceCoordinator MacVoiceHistoryStore MacVoiceKeyBinding MacVoiceKeyBindingRecorder GhosttyRuntime TerminalView; do sources+=("$ROOT/apple/AxoMac/$name.swift"); done
while IFS= read -r path; do sources+=("$path"); done < <(find "$ROOT/apple/AxoMac/Ghostty" -maxdepth 1 -name '*.swift' ! -name Package.swift | sort)
env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -D AXO_NATIVE_FIXTURE -parse-as-library \
  -I "$PRODUCTS" -I "$GHOSTTY/Headers" "${sources[@]}" \
  "$ROOT/apple/AxoMacTests/CentralWorkbenchCatalogChecks.swift" \
  "$PRODUCTS/AxoCore.o" "$PRODUCTS/AxoProtocol.o" "$PRODUCTS/AxoVoice.o" "$GHOSTTY/ghostty-internal.a" \
  -lc++ -framework AppKit -framework Metal -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework IOSurface -framework Carbon -framework IOKit -framework ServiceManagement \
  -framework AVFoundation -framework Speech -o "$TMP/check-central-workbench"
"$TMP/check-central-workbench" "$FIXTURE" "$HELPER"
