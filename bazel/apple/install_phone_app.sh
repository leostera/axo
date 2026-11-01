#!/bin/bash
# Installs the phone app built for a device on the phone named in config.local.json, and
# relaunches it (RFD0021).
#
#   install_phone_app.sh <app.ipa> <device or ""> <bundle id> <status-out> <reason it is off, or "">
#
# It never fails the build: an unplugged or locked phone is reported in the status instead.
set -uo pipefail

ipa=$1
device=$2
bundle_id=$3
status=$4
off=$5

if [[ -n "$off" ]]; then
  printf 'phone install: %s\n' "$off" > "$status"
  exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto -x -k "$ipa" "$stage"
app=$(echo "$stage"/Payload/*.app)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")

if ! output=$(xcrun devicectl device install app --device "$device" "$app" 2>&1); then
  reason=$(printf '%s\n' "$output" | grep -m1 -iE 'error|not (found|connected|paired)|unavailable' || printf '%s\n' "$output" | tail -1)
  printf 'phone install: build %s not installed on %s: %s\n' "$build" "$device" "$reason" > "$status"
  exit 0
fi
if xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle_id" >/dev/null 2>&1; then
  printf 'phone install: build %s installed on %s and opened\n' "$build" "$device" > "$status"
else
  printf 'phone install: build %s installed on %s; the phone is locked, open Axo on it\n' "$build" "$device" > "$status"
fi
