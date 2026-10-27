#!/usr/bin/env bash
# Builds the iPhone app with the next phone build number and, with --install, puts it on the
# phone and opens it.
#
#   scripts/build-phone.sh [--install]
#
# The phone's build numbers are counted on this Mac, apart from the Mac app's, in
# ~/Library/Application Support/Axo/phone-build-number (AXO_PHONE_BUILD_NUMBER overrides).
# AXO_PHONE_DEVICE names the phone (a devicectl identifier); the default is Leo's iPhone.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

install=0
case "${1:-}" in
  --install) install=1 ;;
  "") ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

if [[ -n ${AXO_PHONE_BUILD_NUMBER:-} ]]; then
  build_number=$AXO_PHONE_BUILD_NUMBER
else
  state_dir=${AXO_BUILD_STATE_DIR:-"${HOME:?HOME is required for build numbering}/Library/Application Support/Axo"}
  mkdir -p "$state_dir"
  state_file="$state_dir/phone-build-number"
  lock_dir="$state_file.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Another build is reserving a phone build number; retry after it finishes" >&2
    exit 1
  fi
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
  previous=0
  if [[ -f "$state_file" ]]; then
    previous=$(tr -d '\n' < "$state_file")
    if [[ ! "$previous" =~ ^[0-9]+$ ]]; then
      echo "Phone build-number state is invalid: $state_file" >&2
      exit 1
    fi
  fi
  build_number=$((previous + 1))
  temporary=$(mktemp "$state_file.XXXXXX")
  printf '%s\n' "$build_number" > "$temporary"
  mv -f "$temporary" "$state_file"
  rmdir "$lock_dir"
  trap - EXIT
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "AXO_PHONE_BUILD_NUMBER must be a positive canonical decimal integer" >&2
  exit 1
fi

stamp=(--stamp "--embed_label=axo_phone_build_${build_number}")
bazel build "${stamp[@]}" --ios_multi_cpus=arm64 //apple/AxoPhone:AxoPhoneDevice
ipa=$(bazel cquery "${stamp[@]}" --ios_multi_cpus=arm64 --output=files //apple/AxoPhone:AxoPhoneDevice 2>/dev/null)

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
ditto -x -k "$ipa" "$stage"
app="$stage/Payload/AxoPhoneDevice.app"
stamped=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
if [[ "$stamped" != "$build_number" ]]; then
  echo "The app says build $stamped, not $build_number" >&2
  exit 1
fi
echo "Built phone build $build_number"

if [[ $install -eq 1 ]]; then
  device=${AXO_PHONE_DEVICE:-00008130-00041CE83EFA001C}
  xcrun devicectl device install app --device "$device" "$app" >/dev/null
  echo "Installed on $device"
  if ! xcrun devicectl device process launch --terminate-existing --device "$device" dev.leostera.axo.phone >/dev/null 2>&1; then
    echo "Installed, but the phone is locked: open Axo on it"
  fi
fi
