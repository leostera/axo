#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

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

if [[ -n ${AXO_BUILD_NUMBER:-} ]]; then
  build_number=$AXO_BUILD_NUMBER
else
  build_state_dir=${AXO_BUILD_STATE_DIR:-"${HOME:?HOME is required for local build numbering}/Library/Application Support/Axo"}
  mkdir -p "$build_state_dir"
  build_state_file="$build_state_dir/build-number"
  lock_dir="$build_state_file.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Another build is reserving an Axo build number; retry after it finishes" >&2
    exit 1
  fi
  cleanup_build_number_lock() {
    if [[ -n ${temporary_build_number:-} ]]; then
      rm -f -- "$temporary_build_number"
    fi
    rmdir "$lock_dir" 2>/dev/null || true
  }
  trap cleanup_build_number_lock EXIT

  previous_build_number=$(tr -d '\n' < BUILD_NUMBER)
  if [[ ! "$previous_build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_NUMBER must be a positive canonical decimal integer" >&2
    exit 1
  fi
  if [[ -f "$build_state_file" ]]; then
    saved_build_number=$(tr -d '\n' < "$build_state_file")
    if [[ ! "$saved_build_number" =~ ^[1-9][0-9]*$ ]]; then
      echo "Local Axo build-number state is invalid: $build_state_file" >&2
      exit 1
    fi
    if ((saved_build_number > previous_build_number)); then
      previous_build_number=$saved_build_number
    fi
  fi

  build_number=$((previous_build_number + 1))
  temporary_build_number=$(mktemp "$build_state_file.XXXXXX")
  printf '%s\n' "$build_number" > "$temporary_build_number"
  chmod 600 "$temporary_build_number"
  mv -f "$temporary_build_number" "$build_state_file"
  temporary_build_number=""
  rmdir "$lock_dir"
  trap - EXIT
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "AXO_BUILD_NUMBER must be a positive canonical decimal integer" >&2
  exit 1
fi
export AXO_BUILD_NUMBER="$build_number"

cargo fmt --all --check
cargo clippy --workspace --all-targets --locked --offline -- -D warnings
xcrun swift-format lint --strict --recursive apple/AxoRPC apple/AxoDaemonManager apple/AxoMac/Sources

stamp_flags=(--stamp "--embed_label=axo_build_${build_number}")
bazel test "${stamp_flags[@]}" //...
bazel build "${stamp_flags[@]}" -c opt //apple/AxoMac:AxoApp
app_archive=$(bazel cquery "${stamp_flags[@]}" -c opt --output=files //apple/AxoMac:AxoApp)

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
git_commit=$(git rev-parse --short=8 HEAD)
if ! git diff --quiet -- || [[ -n $(git ls-files --others --exclude-standard) ]]; then
  git_commit="${git_commit}-dirty"
fi
/usr/libexec/PlistBuddy -c "Set :AXOGitCommit $git_commit" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
reported_app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
if [[ "$reported_app_build" != "$build_number" ]]; then
  echo "Axo app reports build $reported_app_build, expected $build_number" >&2
  exit 1
fi
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
  echo "axod reports the wrong build number: $reported_build" >&2
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
