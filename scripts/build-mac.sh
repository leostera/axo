#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework" ]]; then
  echo 'Run scripts/build-ghostty.sh first.' >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then rerun this script.' >&2; exit 1; }
npm --prefix "$ROOT" run build:bridge
(cd "$ROOT/apple" && xcodegen generate)
xcodebuild -project "$ROOT/apple/Axo.xcodeproj" -scheme AxoMac -configuration Debug \
  -derivedDataPath "$ROOT/apple/DerivedData" CODE_SIGNING_ALLOWED=NO build

mkdir -p "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/dist/.axo-package.XXXXXX")"
KEEP_STAGING=0
trap 'if [[ "$KEEP_STAGING" == 0 ]]; then rm -rf "$STAGING"; fi' EXIT
APP="$STAGING/Axo.app"
ditto "$ROOT/apple/DerivedData/Build/Products/Debug/Axo.app" "$APP"

# Fail before replacing the installed artifact if the build lost its Finder config.
REPOSITORY="$(/usr/libexec/PlistBuddy -c Print:AxoRepositoryPath "$APP/Contents/Info.plist")"
if [[ ! -f "$REPOSITORY/scripts/run-pi.sh" ]] || [[ "$(cd "$REPOSITORY" && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]]; then
  echo 'The built app does not point to this Axo checkout; refusing to package it.' >&2
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
