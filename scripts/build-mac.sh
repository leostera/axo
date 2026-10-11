#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_APP="$ROOT/dist/Axo.app"
BUNDLE_ID="dev.leostera.axo.mac"
AGENT_LABEL="dev.leostera.axo.axod"
DISPLAY_NAME="Axo"

if [[ -n "${AXO_INSTANCE_ID:-}" || -n "${AXO_OUTPUT_APP:-}" ]]; then
  echo 'This packaging workflow builds only dist/Axo.app; unset AXO_INSTANCE_ID and AXO_OUTPUT_APP.' >&2
  exit 1
fi
mkdir -p "$ROOT/dist"
if [[ -L "$ROOT/dist" ]]; then
  echo 'Refusing to package through a symlinked dist directory.' >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then rerun this script.' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'Install Rust and Cargo, then rerun this script.' >&2; exit 1; }
cargo build --manifest-path "$ROOT/axod/Cargo.toml" --locked
(cd "$ROOT/apple" && xcodegen generate)
xcodebuild -project "$ROOT/apple/Axo.xcodeproj" -scheme AxoMac -configuration Debug \
  -derivedDataPath "$ROOT/apple/DerivedData" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build

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

# Bundle the installable Axo adapter and its schema libraries, not the ambient Pi engine.
node "$ROOT/scripts/build-pi-adapter.mjs" "$APP/Contents/Resources/pi-axo/index.mjs"

AGENT_PLIST="$APP/Contents/Library/LaunchAgents/dev.leostera.axo.axod.plist"
mkdir -p "$(dirname "$AGENT_PLIST")"
install -m 0644 "$ROOT/apple/AxoMacAxod/dev.leostera.axo.axod.plist" "$AGENT_PLIST"
plutil -lint "$AGENT_PLIST" >/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT_PLIST")" != "Contents/Helpers/axod" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT_PLIST")" != "axod" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$AGENT_PLIST")" != "serve-user" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PLIST")" != "$AGENT_LABEL" ]]; then
  echo 'The staged Axod LaunchAgent does not match the standard Axo app bundle.' >&2
  exit 1
fi
BUNDLED_AXOD_VERSION="$("$APP/Contents/Helpers/axod" --version)"
plutil -insert AxoBundledAxodVersion -string "$BUNDLED_AXOD_VERSION" "$APP/Contents/Info.plist"
COMPATIBLE_AXOD_VERSIONS="$(python3 "$ROOT/scripts/helper-compatible-versions.py" "$ROOT" "$BUNDLED_AXOD_VERSION")"
plutil -insert AxoCompatibleAxodVersions -json "$COMPATIBLE_AXOD_VERSIONS" "$APP/Contents/Info.plist"
BUILD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
plutil -insert AxoBuildCommit -string "$BUILD_COMMIT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
STAGED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c Print:CFBundleIdentifier "$APP/Contents/Info.plist")"
if [[ "$STAGED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo 'The staged Axod-only app has an unexpected bundle identifier.' >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"$DISPLAY_NAME\"" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName \"$DISPLAY_NAME\"" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# ditto preserves Xcode's original bundle-directory dates, even after fresh builds.
# Stamp only the new outer bundle, not its contents or the retained previous package.
PACKAGE_DATE="$(LC_ALL=C date '+%m/%d/%Y %H:%M:%S')"
xcrun SetFile -d "$PACKAGE_DATE" -m "$PACKAGE_DATE" "$APP"

# Atomic same-filesystem replacement preserves a running bundle's mapped files and a rollback copy.
# Never stop a process or touch Application Support while packaging.
python3 - "$APP" "$OUTPUT_APP" <<'PY'
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
codesign --verify --deep --strict "$OUTPUT_APP"
printf '\nBuilt %s\nBundled helper: %s/Contents/Helpers/axod\n' "$OUTPUT_APP" "$OUTPUT_APP"
