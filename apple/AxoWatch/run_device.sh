#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 <iPhone device identifier> <Watch device identifier>" >&2
  exit 2
fi
phone_device=$1
watch_device=$2
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

# Use the real companion build, not a separate Xcode build of the Watch's sources.
# Profiles must already be installed; this command never registers devices or changes Apple accounts.
bazel build //apple/AxoPhone:AxoPhone_ipa --watchos_cpus=device_arm64
outputs=$(bazel cquery //apple/AxoPhone:AxoPhone_ipa --watchos_cpus=device_arm64 --output=files)
ipa=$(printf '%s\n' "$outputs" | awk '/\.ipa$/ { print; count++ } END { if (count != 1) exit 1 }') || {
  echo "No signed companion IPA. Install the phone, Watch, and complication development profiles first (see README.md)." >&2
  exit 1
}
[[ -f "$ipa" ]] || { echo "Missing IPA: $ipa" >&2; exit 1; }

artifacts=$(mktemp -d "${TMPDIR:-/tmp}/axo-watch-companion.XXXXXX")
echo "Preserved device verification artifacts: $artifacts"
ditto -x -k "$ipa" "$artifacts"
phone="$artifacts/Payload/AxoPhoneDevice.app"
watch="$phone/Watch/AxoWatchApp.app"
[[ -d "$phone" && -d "$watch" ]] || { echo "Missing companion bundles" >&2; exit 1; }
codesign --verify --deep --strict "$phone"
python3 - "$phone" "$watch" <<'PY'
import pathlib, plistlib, sys
phone, watch = map(pathlib.Path, sys.argv[1:])
widget = watch / 'PlugIns/AxoWatchComplicationExtension.appex'
def info(bundle):
    return plistlib.loads((bundle / 'Info.plist').read_bytes())
p, w, c = map(info, [phone, watch, widget])
assert p['CFBundleVersion'] == w['CFBundleVersion'] == c['CFBundleVersion'], 'Companion build versions differ'
assert c['CFBundleIdentifier'] == w['CFBundleIdentifier'] + '.complications', 'Unexpected complication identity'
assert c.get('CFBundleName') and c.get('CFBundlePackageType') == 'XPC!', 'Invalid extension bundle metadata'
assert c['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension', 'Not a WidgetKit extension'
assert w['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon', 'Missing Watch brand icon'
print('Verified: signed mascot complication, Watch app icon, and matching companion versions.')
PY

xcrun devicectl device install app --device "$phone_device" "$phone" --timeout 90 --json-output "$artifacts/phone-install.json"
# Explicit installation avoids waiting for the iPhone's automatic Watch-install queue during development.
xcrun devicectl device install app --device "$watch_device" "$watch" --timeout 90 --json-output "$artifacts/watch-install.json"
phone_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$phone/Info.plist")
watch_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$watch/Info.plist")
xcrun devicectl device process launch --device "$phone_device" --terminate-existing "$phone_bundle" --timeout 30 --json-output "$artifacts/phone-launch.json"
xcrun devicectl device process launch --device "$watch_device" --terminate-existing "$watch_bundle" --timeout 30 --json-output "$artifacts/watch-launch.json"
xcrun devicectl device info processes --device "$watch_device" --timeout 30 --json-output "$artifacts/watch-processes.json" >/dev/null
python3 - "$artifacts" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
launch = json.loads((root / 'watch-launch.json').read_text())
processes = json.loads((root / 'watch-processes.json').read_text())
result = launch.get('result', {})
pid = result.get('process', {}).get('processIdentifier')
if pid is None:
    raise SystemExit('Watch launch returned no process identifier; inspect preserved JSON artifacts')
running = processes.get('result', {}).get('runningProcesses', [])
if not any(p.get('processIdentifier') == pid for p in running):
    raise SystemExit('The newly launched Watch process is no longer running')
print(f'Verified: companion Watch app is running (PID {pid}).')
print('Sign in once on the iPhone if needed; the Watch uses that same login automatically.')
PY
