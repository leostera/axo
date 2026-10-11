#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION=7ec9e26a29399b30ef78f06985fc75045b3cecb6
VENDOR="$ROOT/vendor/ghostty"
if [[ "$(git -C "$VENDOR" rev-parse HEAD)" != "$REVISION" ]] || ! git -C "$VENDOR" diff --quiet; then
  echo 'The VT characterization requires the clean pinned Ghostty source.' >&2
  exit 1
fi
if [[ ! -f "$VENDOR/zig-out/lib/libghostty-vt.dylib" ]]; then
  echo 'Build the pinned public VT library first: zig build -Demit-lib-vt -Demit-macos-app=false' >&2
  exit 1
fi
TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/axo-vt-snapshot.XXXXXX")"
trap 'rm -rf "$TEMPORARY"' EXIT
# The local Zig archive uses GNU ar metadata rejected by Apple's linker. Use
# its Mach-O dylib for this isolated characterization; this is not packaging.
env -u LIBRARY_PATH clang -std=c11 -Wall -Wextra -Werror \
  -I "$VENDOR/include" "$ROOT/axod/tests/fixtures/ghostty_vt_snapshot.c" \
  -L "$VENDOR/zig-out/lib" -lghostty-vt -Wl,-rpath,"$VENDOR/zig-out/lib" \
  -o "$TEMPORARY/check"
printf 'Ghostty source: %s\n' "$REVISION"
"$TEMPORARY/check"
