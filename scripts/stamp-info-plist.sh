#!/usr/bin/env bash
set -euo pipefail

source_plist=$1
fallback_build_number_file=$2
output_plist=$3

build_number=${AXO_BUILD_NUMBER:-$(tr -d '\r\n' < "$fallback_build_number_file")}
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "AXO_BUILD_NUMBER must be a positive canonical decimal integer" >&2
  exit 1
fi

cp "$source_plist" "$output_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$output_plist"
