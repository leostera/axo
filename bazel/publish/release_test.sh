#!/usr/bin/env bash
set -euo pipefail
source "$1"
release_newer 0.71 0.9
release_newer 1.0 0.99
if release_newer 0.71 0.71 || release_newer 0.9 0.71 || release_newer bad 0.71; then exit 1; fi
[[ "$(release_target arm64)" == aarch64-apple-darwin ]]
[[ "$(release_target x86_64)" == x86_64-apple-darwin ]]
[[ "$(release_target 'x86_64 arm64')" == universal-apple-darwin ]]
if release_target amd64; then exit 1; fi
commit=0123456789abcdef0123456789abcdef01234567
[[ "$(release_filename 0.71 "$commit" aarch64-apple-darwin)" == axo-0.71-0123456789ab-aarch64-apple-darwin.zip ]]
if release_filename 0.71 short aarch64-apple-darwin || release_filename 0.71 "$commit" ../escape; then exit 1; fi
file="${TEST_TMPDIR:-${TMPDIR:-/tmp}}/release-manifest-$$.json"
trap 'rm -f "$file"' EXIT
release_manifest "$file" 0.71 342 94 "$commit" aarch64-apple-darwin
[[ "$(/usr/bin/plutil -extract version raw -o - "$file")" == 0.71 ]]
[[ "$(/usr/bin/plutil -extract commit raw -o - "$file")" == "$commit" ]]
[[ "$(/usr/bin/plutil -extract artifacts.aarch64-apple-darwin raw -o - "$file")" == axo-0.71-0123456789ab-aarch64-apple-darwin.zip ]]
echo "release identity/manifest tests pass"
