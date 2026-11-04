#!/bin/bash
# Unpacks the Mac app rules_apple built and signs it for launchd: helper, embedded frameworks,
# then the app, with the hardened runtime and a secure timestamp (RFD0021).
#
#   sign_mac_app.sh <app.zip> <out/Axo.app> <status-out> <identity or "">
#
# It never fails the build over signing: without an identity, or when codesign cannot use it, the
# app is signed ad hoc and the status says why. launchd will not run an ad hoc signed axod.
set -euo pipefail

archive=$1
app=$2
status=$3
identity=$4

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto -x -k "$archive" "$stage"
rm -rf "$app"
mkdir -p "$(dirname "$app")"
/usr/bin/ditto "$stage/Axo.app" "$app"
chmod -R u+w "$app"
# rules_apple's zip dates every entry 1980 for reproducible archives, and ditto keeps that, so
# Finder would show the app's files as decades old. Date them now, when this app is built; times
# are not part of the signature.
find "$app" -exec touch -h {} +
# axod's signing identifier must stay "axod". Background Task Management records it when Axo
# registers the LaunchAgent, and launchd then refuses any other one with a Launch Constraint
# Violation (OS_REASON_CODESIGNING), so axod never starts. Changing it needs Axo to unregister
# and register the agent again on every Mac first.
axod_identifier=axod

sign_all() {
  local id=$1
  shift
  /usr/bin/codesign --force --sign "$id" --identifier "$axod_identifier" "$@" \
    "$app/Contents/Helpers/axod" &&
    /usr/bin/codesign --force --sign "$id" --identifier dev.leostera.axo.decide "$@" \
      "$app/Contents/Helpers/axo-decide" &&
    for framework in "$app"/Contents/Frameworks/*.framework; do
      [[ -e "$framework" ]] || continue
      # Vendor frameworks (RiveRuntime) come signed by their vendor; the hardened runtime's
      # library validation only loads code signed by the app's own team.
      /usr/bin/codesign --force --sign "$id" "$@" "$framework" || return 1
    done &&
    /usr/bin/codesign --force --sign "$id" "$@" "$app"
}

how=""
if [[ -n "$identity" ]]; then
  if sign_all "$identity" --options runtime --timestamp 2>"$stage/codesign.log"; then
    how="signed"
  elif sign_all "$identity" --options runtime 2>"$stage/codesign.log"; then
    how="signed without a secure timestamp (no network?)"
  else
    how="ad hoc: codesign could not use the identity: $(tail -1 "$stage/codesign.log")"
  fi
else
  how="ad hoc: no signing identity for the team (launchd will not run its axod)"
fi
if [[ "$how" == ad\ hoc* ]]; then
  sign_all - --options runtime
fi
/usr/bin/codesign --verify --deep --strict "$app"

build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
axod=$(/usr/libexec/PlistBuddy -c 'Print :AXODBuildNumber' "$app/Contents/Info.plist")
team=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')
if [[ "$how" == signed* ]]; then
  how="$how by $team"
fi
printf 'Axo.app build %s (axod %s): %s\n' "$build" "$axod" "$how" > "$status"
