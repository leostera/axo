#!/usr/bin/env bash
# Publish immutable target-qualified archives, then advance the single latest.json pointer.
# Single writer: version/build must increase. Existing clients use Worker-derived legacy views.
set -euo pipefail
app=$1 zip=$2 cf=$3 team=$4 bucket=$5 url=$6
source "$7"
cdn=${url%/*}
root=${BUILD_WORKSPACE_DIRECTORY:?run me with bazel run //:publish}
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "Commit checkout changes before publishing." >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
signed_by=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$signed_by" == "$team" ]] || { echo "App is not signed by the configured team" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/axo-publish.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
# Published copies are writable so macOS can move/install them. Modes are not signed.
ditto -x -k "$zip" "$work"
codesign --verify --deep --strict "$work/Axo.app"
[[ "$(cdhash "$app")" == "$(cdhash "$work/Axo.app")" ]] || { echo "Archive signature differs from build" >&2; exit 1; }
chmod -R u+w "$work/Axo.app"
ditto -c -k --keepParent "$work/Axo.app" "$work/archive.zip"
ditto -x -k "$work/archive.zip" "$work/check"
codesign --verify --deep --strict "$work/check/Axo.app"
[[ "$(cdhash "$app")" == "$(cdhash "$work/check/Axo.app")" ]] || exit 1
[[ -z "$(find "$work/check" ! -perm -u+w -print -quit)" ]] || { echo "Archive has read-only files" >&2; exit 1; }
zip=$work/archive.zip
plist=$app/Contents/Info.plist
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
axod_build=$(/usr/libexec/PlistBuddy -c 'Print :AXODBuildNumber' "$plist")
embedded_commit=$(/usr/libexec/PlistBuddy -c 'Print :AXOGitCommit' "$plist")
[[ "$embedded_commit" =~ ^[a-f0-9]{7,40}$ ]] || { echo "Invalid embedded Git commit" >&2; exit 1; }
commit=$(git -C "$root" rev-parse --verify "$embedded_commit^{commit}")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
target=$(release_target "$(lipo -archs "$app/Contents/MacOS/Axo")")
filename=$(release_filename "$version" "$commit" "$target")
manifest=$work/latest.json
release_manifest "$manifest" "$version" "$build" "$axod_build" "$commit" "$target"
# Only a missing pointer is a bootstrap case. Network/server/malformed-data errors fail closed.
status=$(curl -sS -o "$work/current.json" -w '%{http_code}' "$cdn/latest.json")
if [[ "$status" == 404 ]]; then
  status=$(curl -sS -o "$work/current.json" -w '%{http_code}' "$cdn/Axo.app.json")
fi
if [[ "$status" == 200 ]]; then
  published_version=$(/usr/bin/plutil -extract version raw -o - "$work/current.json")
  published_build=$(/usr/bin/plutil -extract build raw -o - "$work/current.json")
  [[ "$published_build" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "Invalid published build" >&2; exit 1; }
  release_newer "$version" "$published_version" || { echo "Raise the release version above $published_version" >&2; exit 1; }
  (( build > published_build )) || { echo "Raise builds.mac above $published_build" >&2; exit 1; }
elif [[ "$status" != 404 ]]; then
  echo "Could not inspect published release (HTTP $status)" >&2; exit 1
fi
# A failed prior publication may already have uploaded this name. Reuse identical signed
# content, never overwrite an immutable URL. The Worker routes must be deployed first.
status=$(curl -sS -o "$work/existing.zip" -w '%{http_code}' "$cdn/$filename")
if [[ "$status" == 200 ]]; then
  ditto -x -k "$work/existing.zip" "$work/existing"
  codesign --verify --deep --strict "$work/existing/Axo.app"
  [[ "$(cdhash "$app")" == "$(cdhash "$work/existing/Axo.app")" ]] || { echo "Immutable artifact already exists with different content" >&2; exit 1; }
  echo "Reusing verified immutable archive: $filename"
elif [[ "$status" == 404 ]]; then
  "$cf" r2 objects put "releases/$filename" --bucket-name "$bucket" --file "$zip" \
    --content-type application/zip --content-length "$(stat -L -f %z "$zip")" --quiet >/dev/null
else
  echo "Could not inspect immutable artifact (HTTP $status)" >&2; exit 1
fi
# Last write: a failed archive upload cannot make latest point to absent data.
"$cf" r2 objects put latest.json --bucket-name "$bucket" --file "$manifest" \
  --content-type application/json --content-length "$(stat -f %z "$manifest")" --quiet >/dev/null
echo "Published Axo $version ($target, build $build, axod $axod_build): $cdn/$filename"
echo "Latest: $cdn/latest.json"
