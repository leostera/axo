#!/usr/bin/env bash
# Uploads a packaged Axo.app (default: dist/Axo.app) for https://axo.leostera.dev/cdn/Axo.app,
# which `curl -fsSL https://axo.leostera.dev/install | sh` installs.
#
# Every build is kept at mac/builds/<CFBundleVersion>/Axo.app.zip in the axo-downloads bucket;
# mac/Axo.app.zip is the one served. A build from a dirty tree is refused unless
# AXO_PUBLISH_ALLOW_DIRTY=1.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=$(cd "$(dirname "${1:-$root/dist/Axo.app}")" && pwd)/$(basename "${1:-$root/dist/Axo.app}")
bucket=${AXO_DOWNLOADS_BUCKET:-axo-downloads}
# The install script refuses any other signing team.
team_id=RGH6S9S55G

[[ -d "$app" ]] || { echo "No app at $app; run scripts/build-mac.sh first" >&2; exit 1; }

codesign --verify --deep --strict "$app"
team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$team" != "$team_id" ]]; then
  echo "$app is signed by team '$team', not $team_id" >&2
  exit 1
fi
plist=$app/Contents/Info.plist
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
axod_build=$(/usr/libexec/PlistBuddy -c 'Print :AXODBuildNumber' "$plist")
commit=$(/usr/libexec/PlistBuddy -c 'Print :AXOGitCommit' "$plist")
if [[ "$commit" == *-dirty && ${AXO_PUBLISH_ALLOW_DIRTY:-} != 1 ]]; then
  echo "$app was built from a dirty tree ($commit); rebuild from a clean one or set AXO_PUBLISH_ALLOW_DIRTY=1" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/axo-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT
zip=$work/Axo.app.zip
# ditto keeps the bundle's symlinks, permissions and signature intact.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
size=$(stat -f %z "$zip")

upload() {
  # Run from the site so cf uses its account.
  (cd "$root/sites/axo.leostera.dev" &&
    cf r2 objects put "$1" --bucket-name "$bucket" --file "$zip" \
      --content-type application/zip --content-length "$size" --quiet >/dev/null)
}

echo "Uploading Axo build $build (axod $axod_build, $commit, $((size / 1024 / 1024)) MiB)"
upload "mac/builds/$build/Axo.app.zip"
upload "mac/Axo.app.zip"
echo "Published: https://axo.leostera.dev/cdn/Axo.app"
echo "Install:   curl -fsSL https://axo.leostera.dev/install | sh"
