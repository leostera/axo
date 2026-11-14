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
native=${6:-}
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
for executable in "$app/Contents/MacOS/Axo" "$app/Contents/Helpers/axod" "$app/Contents/Helpers/axod-infer"; do
  check "minos of ${executable##*/}" "$(xcrun vtool -show-build "$executable" | awk '/minos/ { print $2; exit }')" "$macos_min"
done
if [[ "$native" == mlx ]]; then
  helper="$app/Contents/Helpers/axod-infer-mlx"
  for resource in "$helper" "$app/Contents/Resources/MLX/mlx.metallib" "$app/Contents/Resources/ThirdParty/MLX-third-party-notices.txt"; do
    if [[ ! -s "$resource" ]]; then
      echo "FAIL: missing native MLX component: $resource" >&2
      failures=$((failures + 1))
    fi
  done
  check "minos of axod-infer-mlx" "$(xcrun vtool -show-build "$helper" | awk '/minos/ { print $2; exit }')" "$macos_min"
  check "MLX signing identifier" "$(codesign -dv "$helper" 2>&1 | awk -F= '/^Identifier=/ { print $2 }')" dev.leostera.axo.infer.mlx
  if [[ "$team" != - ]]; then
    check "MLX worker team" "$(codesign -dv --verbose=4 "$helper" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
  fi
  if capabilities=$("$helper" --capabilities); then
    check "packaged native MLX device" "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract available raw -o - -)" true
  else
    echo "FAIL: packaged native MLX capability query cannot run" >&2
    failures=$((failures + 1))
  fi
fi
coreml="$app/Contents/Helpers/axod-infer-coreml"
if [[ ! -s "$coreml" ]]; then
  echo "FAIL: missing native Core ML worker" >&2
  failures=$((failures + 1))
else
  check "minos of axod-infer-coreml" "$(xcrun vtool -show-build "$coreml" | awk '/minos/ { print $2; exit }')" "$macos_min"
  check "Core ML signing identifier" "$(codesign -dv "$coreml" 2>&1 | awk -F= '/^Identifier=/ { print $2 }')" dev.leostera.axo.infer.coreml
  if [[ "$team" != - ]]; then
    check "Core ML worker team" "$(codesign -dv --verbose=4 "$coreml" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
  fi
  if capabilities=$("$coreml" --capabilities); then
    check "packaged native Core ML devices" "$(printf '%s' "$capabilities" | /usr/bin/plutil -extract available raw -o - -)" true
  else
    echo "FAIL: packaged native Core ML capability query cannot run" >&2
    failures=$((failures + 1))
  fi
fi
check "axod --version" "$("$app/Contents/Helpers/axod" --version | sed -n 's/.*(build \([0-9]*\)).*/\1/p')" "$axod_build"
for agent in dev.leostera.axo.axod dev.leostera.axo.app; do
  if plutil -lint "$app/Contents/Library/LaunchAgents/$agent.plist" >/dev/null; then
    echo "ok: LaunchAgent $agent plist lints"
  else
    echo "FAIL: LaunchAgent $agent plist is missing or does not lint" >&2
    failures=$((failures + 1))
  fi
done
check "Axo's agent's program" "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$app/Contents/Library/LaunchAgents/dev.leostera.axo.app.plist")" Contents/MacOS/Axo
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
# The identifier the registered LaunchAgent was approved with; see sign_mac_app.sh.
check "axod's signing identifier" "$(codesign -dv "$app/Contents/Helpers/axod" 2>&1 | sed -n 's/^Identifier=//p')" axod
if [[ "$team" != - ]]; then
  check "app's team" "$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
  check "axod's team" "$(codesign -dv --verbose=4 "$app/Contents/Helpers/axod" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
  check "axod-infer's team" "$(codesign -dv --verbose=4 "$app/Contents/Helpers/axod-infer" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')" "$team"
fi
exit "$failures"
