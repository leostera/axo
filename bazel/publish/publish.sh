#!/usr/bin/env bash
# bazel run //:publish: uploads the Mac app this build signed for https://axo.leostera.dev/cdn/Axo.app,
# which `curl -fsSL https://axo.leostera.dev/install | sh` installs (RFD0021).
#
# Every build is kept at mac/builds/<CFBundleVersion>/Axo.app.zip; mac/Axo.app.zip is the one served.
# It refuses an app not signed by the team, and a checkout with changes: what is published must be
# a commit.
set -euo pipefail

app=$1 zip=$2 cf=$3 team=$4 bucket=$5 url=$6

root=${BUILD_WORKSPACE_DIRECTORY:?run me with bazel run //:publish}
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "The checkout has changes; commit them first, so the published app is a commit:" >&2
  git -C "$root" status --short >&2
  exit 1
fi

codesign --verify --deep --strict "$app"
signed_by=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$signed_by" != "$team" ]]; then
  echo "The app is signed by team '${signed_by:-none}', not $team; this Mac cannot sign for it (see bazel-bin/report.txt)" >&2
  exit 1
fi

plist=$app/Contents/Info.plist
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
axod_build=$(/usr/libexec/PlistBuddy -c 'Print :AXODBuildNumber' "$plist")
commit=$(/usr/libexec/PlistBuddy -c 'Print :AXOGitCommit' "$plist")
size=$(stat -f %z "$zip")
zip=$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")

upload() {
  "$cf" r2 objects put "$1" --bucket-name "$bucket" --file "$zip" \
    --content-type application/zip --content-length "$size" --quiet >/dev/null
}

echo "Uploading Axo build $build (axod $axod_build, $commit, $((size / 1024 / 1024)) MiB)"
upload "mac/builds/$build/Axo.app.zip"
upload "mac/Axo.app.zip"
echo "Published: $url"
echo "Install:   curl -fsSL https://axo.leostera.dev/install | sh"
