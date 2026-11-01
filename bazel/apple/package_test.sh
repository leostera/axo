#!/bin/bash
# Checks the signed Mac app is what config.json describes and can run axod (RFD0021):
# build numbers, both executables' minimum macOS, axod's reported build, the LaunchAgent plist,
# and, when this Mac can sign, the team in config.json for both app and helper.
#
#   package_test.sh <Axo.app> <mac build> <axod build> <macOS minimum> <team, or - for ad hoc>
set -euo pipefail

# The bundle itself, not the runfiles' symlink to it: codesign checks its symlinks.
app=$(cd -P "$1" && pwd)
build=$2
axod_build=$3
macos_min=$4
team=$5
plist="$app/Contents/Info.plist"
failures=0

check() {
  if [[ "$2" != "$3" ]]; then
    echo "FAIL: $1: got '$2', expected '$3'" >&2
    failures=$((failures + 1))
  else
    echo "ok: $1 = $2"
  fi
}

check CFBundleVersion "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" "$build"
check AXODBuildNumber "$(/usr/libexec/PlistBuddy -c 'Print :AXODBuildNumber' "$plist")" "$axod_build"
check LSMinimumSystemVersion "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" "$macos_min"
for executable in "$app/Contents/MacOS/Axo" "$app/Contents/Helpers/axod"; do
  check "minos of ${executable##*/}" "$(xcrun vtool -show-build "$executable" | awk '/minos/ { print $2; exit }')" "$macos_min"
done
check "axod --version" "$("$app/Contents/Helpers/axod" --version | sed -n 's/.*(build \([0-9]*\)).*/\1/p')" "$axod_build"
if plutil -lint "$app/Contents/Library/LaunchAgents/dev.leostera.axo.axod.plist" >/dev/null; then
  echo "ok: LaunchAgent plist lints"
else
  echo "FAIL: LaunchAgent plist does not lint" >&2
  failures=$((failures + 1))
fi
if [[ -f "$app/Contents/Resources/AxoPi/index.js" ]]; then
  echo "ok: Pi extension bundled"
else
  echo "FAIL: no Pi extension in Resources/AxoPi" >&2
  failures=$((failures + 1))
fi
if ! codesign --verify --deep --strict "$app"; then
  echo "FAIL: signature does not verify" >&2
  failures=$((failures + 1))
fi
if [[ "$team" != - ]]; then
  check "app's team" "$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
  check "axod's team" "$(codesign -dv --verbose=4 "$app/Contents/Helpers/axod" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
fi
exit "$failures"
