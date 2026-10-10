#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCE_ID="${AXO_INSTANCE_ID:-default}"
OUTPUT_APP="${AXO_OUTPUT_APP:-$ROOT/dist/Axo.app}"

if [[ ! "$INSTANCE_ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || ${#INSTANCE_ID} -gt 32 ]]; then
  echo 'AXO_INSTANCE_ID must be 1-32 lowercase letters/digits separated by single hyphens.' >&2
  exit 1
fi
if [[ "$INSTANCE_ID" != "default" && -z "${AXO_OUTPUT_APP:-}" ]]; then
  echo 'A non-default instance needs AXO_OUTPUT_APP so it cannot replace the default app.' >&2
  exit 1
fi
if [[ "$OUTPUT_APP" != /* ]]; then OUTPUT_APP="$ROOT/$OUTPUT_APP"; fi
mkdir -p "$ROOT/dist"
if [[ -L "$ROOT/dist" ]]; then
  echo 'Refusing to package through a symlinked dist directory.' >&2
  exit 1
fi
if [[ "$(dirname "$OUTPUT_APP")" != "$ROOT/dist" || "$OUTPUT_APP" != *.app ]]; then
  echo 'AXO_OUTPUT_APP must be a .app directly inside this checkout dist directory.' >&2
  exit 1
fi
if [[ "$INSTANCE_ID" != "default" && "$OUTPUT_APP" == "$ROOT/dist/Axo.app" ]]; then
  echo 'A named test instance must not replace dist/Axo.app.' >&2
  exit 1
fi
if [[ "$INSTANCE_ID" != "default" && ( -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ) ]]; then
  echo 'Named test bundles are immutable build slots; choose a fresh AXO_INSTANCE_ID and AXO_OUTPUT_APP.' >&2
  exit 1
fi
AGENT_LABEL="dev.leostera.axo.axod"
DISPLAY_NAME="Axo"
if [[ "$INSTANCE_ID" == "default" ]]; then
  BUNDLE_ID="dev.leostera.axo.mac"
else
  BUNDLE_ID="dev.leostera.axo.mac.$INSTANCE_ID"
  AGENT_LABEL+=".$INSTANCE_ID"
  DISPLAY_NAME="Axo ($INSTANCE_ID)"
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

AGENT_PLIST="$APP/Contents/Library/LaunchAgents/dev.leostera.axo.axod.plist"
mkdir -p "$(dirname "$AGENT_PLIST")"
install -m 0644 "$ROOT/apple/AxoMacAxod/dev.leostera.axo.axod.plist" "$AGENT_PLIST"
python3 - "$AGENT_PLIST" "$INSTANCE_ID" <<'PY'
import plistlib, sys
path, instance = sys.argv[1:]
with open(path, "rb") as source:
    plist = plistlib.load(source)
label = "dev.leostera.axo.axod"
arguments = ["axod", "serve-user"]
if instance != "default":
    label += "." + instance
    arguments += ["--instance-id", instance]
plist["Label"] = label
plist["ProgramArguments"] = arguments
with open(path, "wb") as destination:
    plistlib.dump(plist, destination, fmt=plistlib.FMT_XML, sort_keys=True)
PY
plutil -lint "$AGENT_PLIST" >/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT_PLIST")" != "Contents/Helpers/axod" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$AGENT_PLIST")" != "serve-user" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PLIST")" != "$AGENT_LABEL" ]]; then
  echo 'The staged Axod LaunchAgent does not match this app instance.' >&2
  exit 1
fi
STAGED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c Print:CFBundleIdentifier "$APP/Contents/Info.plist")"
if [[ "$STAGED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo 'The staged Axod-only app has an unexpected bundle identifier.' >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"$DISPLAY_NAME\"" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName \"$DISPLAY_NAME\"" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

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
