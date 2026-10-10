#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then rerun this script.' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'Install Rust and Cargo, then rerun this script.' >&2; exit 1; }
cargo build --manifest-path "$ROOT/axod/Cargo.toml" --locked
(cd "$ROOT/apple" && xcodegen generate)
xcodebuild -project "$ROOT/apple/Axo.xcodeproj" -scheme AxoMac -configuration Debug \
  -derivedDataPath "$ROOT/apple/DerivedData" CODE_SIGNING_ALLOWED=NO build

mkdir -p "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/dist/.axo-package.XXXXXX")"
KEEP_STAGING=0
trap 'if [[ "$KEEP_STAGING" == 0 ]]; then rm -rf "$STAGING"; fi' EXIT
APP="$STAGING/Axo.app"
ditto "$ROOT/apple/DerivedData/Build/Products/Debug/Axo.app" "$APP"
mkdir -p "$APP/Contents/Helpers"
install -m 0755 "$ROOT/axod/target/debug/axod" "$APP/Contents/Helpers/axod"
if [[ ! -x "$APP/Contents/Helpers/axod" ]]; then
  echo 'The staged app does not contain its executable axod helper.' >&2
  exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c Print:CFBundleIdentifier "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "dev.leostera.axo.mac" ]]; then
  echo 'The staged Axod-only app has an unexpected bundle identifier.' >&2
  exit 1
fi
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Atomic same-filesystem replacement preserves the running bundle's mapped files and a rollback copy.
# Never stop a process or touch Application Support while packaging.
python3 - "$APP" "$ROOT/dist/Axo.app" <<'PY'
import ctypes, os, pathlib, sys
staged, destination = sys.argv[1:]
if pathlib.Path(destination).is_symlink():
    raise RuntimeError("Refusing to replace a symlinked app bundle")
if os.path.exists(destination):
    libc = ctypes.CDLL(None, use_errno=True)
    swap = libc.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(staged), os.fsencode(destination), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    print("Previous app retained at:", staged)
else:
    os.rename(staged, destination)
PY
if [[ -d "$APP" ]]; then KEEP_STAGING=1; fi
codesign --verify --deep --strict "$ROOT/dist/Axo.app"
printf '\nBuilt %s\nDouble-click Axo.app in Finder to launch it.\n' "$ROOT/dist/Axo.app"
