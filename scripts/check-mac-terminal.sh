#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/axo-terminal.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PRODUCTS="$ROOT/apple/DerivedData/Build/Products/Debug"
GHOSTTY="$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
HELPER="${AXO_LOCAL_DAEMON_BINARY:-$ROOT/axod/target/debug/axod}"
CLI="${AXO_LOCAL_CLI_BINARY:-$ROOT/axod/target/debug/axo}"
[[ -f "$PRODUCTS/AxoProtocol.o" && -x "$HELPER" && -x "$CLI" ]] || { echo 'Build the Mac target and owned helper/CLI before terminal checks.' >&2; exit 1; }
compile_check() {
  env -u LIBRARY_PATH xcrun swiftc -swift-version 5 -parse-as-library \
    -I "$PRODUCTS" -I "$GHOSTTY/Headers" \
    "$ROOT/apple/AxoMac/GhosttyRuntime.swift" "$ROOT/apple/AxoMac/TerminalView.swift" \
    "$ROOT/apple/AxoMacAxod/TerminalLaunch.swift" "$ROOT/apple/AxoMacAxod/AxodTerminalSurfaces.swift" \
    "$ROOT/apple/AxoMacAxod/AxodTerminalHost.swift" "$ROOT/apple/AxoMacAxod/AxodPaneFocusDirection.swift" \
    "$ROOT/apple/AxoMacAxod/AxodPaneLayoutLeaf.swift" "$ROOT/apple/AxoMac/Ghostty/SplitTree.swift" \
    "$ROOT/apple/AxoMac/Ghostty/Array+Extension.swift" "$ROOT/apple/AxoMac/Ghostty/PointerBackport.swift" \
    "$ROOT/apple/AxoMacTests/$1.swift" \
    "$PRODUCTS/AxoProtocol.o" "$GHOSTTY/ghostty-internal.a" \
    -lc++ -framework AppKit -framework Metal -framework QuartzCore -framework CoreText \
    -framework CoreGraphics -framework IOSurface -framework Carbon -framework IOKit \
    -o "$TMP/$1"
}
compile_check TerminalSurfaceChecks
"$TMP/TerminalSurfaceChecks" "$HELPER"
compile_check NativeTerminalFixtureChecks
cargo build --manifest-path "$ROOT/axod/Cargo.toml" --locked --offline --example native-terminal-fixture
"$ROOT/axod/target/debug/examples/native-terminal-fixture" "$TMP/NativeTerminalFixtureChecks" "$HELPER" "$CLI"
