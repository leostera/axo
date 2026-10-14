#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

build_number=$(tr -d '\n' < BUILD_NUMBER)
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_NUMBER must be a positive canonical decimal integer" >&2
  exit 1
fi

identity=${AXO_MAC_SIGNING_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identities=()
  while IFS= read -r fingerprint; do
    identities+=("$fingerprint")
  done < <(security find-identity -v -p codesigning \
    | awk '/^[[:space:]]*[0-9]+\)/ { print $2 }')
  if [[ ${#identities[@]} -ne 1 ]]; then
    echo "Set AXO_MAC_SIGNING_IDENTITY to one valid signing fingerprint" >&2
    exit 1
  fi
  identity=${identities[0]}
fi

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

cargo fmt --all --check
cargo clippy --workspace --all-targets --locked --offline -- -D warnings
xcrun swift-format lint --strict --recursive apple/AxoRPC apple/AxoDaemonManager apple/AxoMac/Sources

bazel test //...
bazel build -c opt //apple/AxoMac:AxoApp //crates/axod:axod
app_archive=$(bazel cquery -c opt --output=files //apple/AxoMac:AxoApp)
daemon_binary=$(bazel cquery -c opt --output=files //crates/axod:axod)

mkdir -p dist
stage=$(mktemp -d "$root/dist/.Axo-stage.XXXXXX")
app="$stage/Axo.app"
preserve_stage=0
cleanup() {
  if [[ "$preserve_stage" -eq 0 ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

ditto -x -k "$app_archive" "$stage"
mkdir -p "$app/Contents/Helpers"
cp "$daemon_binary" "$app/Contents/Helpers/axod"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Library/LaunchAgents/dev.leostera.axo.axod.plist"
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
for executable in "$app/Contents/MacOS/Axo" "$app/Contents/Helpers/axod"; do
  executable_minimum_os=$(xcrun vtool -show-build "$executable" | awk '/minos/ { print $2; exit }')
  if [[ "$executable_minimum_os" != "$minimum_os" ]]; then
    echo "$executable targets macOS $executable_minimum_os, not $minimum_os" >&2
    exit 1
  fi
done
reported_build=$("$app/Contents/Helpers/axod" --version)
if [[ "$reported_build" != *"(build $build_number)" ]]; then
  echo "Axo D reports the wrong build number: $reported_build" >&2
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Helpers/axod"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict "$app/Contents/Helpers/axod"
codesign --verify --deep --strict "$app"

helper_team=$(codesign -dv --verbose=4 "$app/Contents/Helpers/axod" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')
app_team=$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')
if [[ -z "$helper_team" || "$helper_team" != "$app_team" ]]; then
  echo "Axo app and daemon must be signed by the same team" >&2
  exit 1
fi

xcrun swift scripts/replace-app.swift "$app" "$root/dist/Axo.app"
if [[ -d "$stage/Axo.app" ]]; then
  echo "Previous Axo.app retained for rollback at $stage/Axo.app"
  preserve_stage=1
fi

printf 'Built and signed: %s/dist/Axo.app\nBuild number: %s\nSigning team: %s\n' \
  "$root" "$build_number" "$app_team"
