#!/usr/bin/env bash
# bazel run //apple/AxoPhone:record_snapshots: makes the screenshots of the last run of the phone
# UI tests the reviewed baselines in apple/AxoPhone/Snapshots/Phone. Review them first: they are in
# bazel-testlogs/apple/AxoPhone/AxoPhoneUITests/test.outputs/snapshots (RFD0021).
set -euo pipefail

root=${BUILD_WORKSPACE_DIRECTORY:?run me with bazel run //apple/AxoPhone:record_snapshots}
outputs=$root/bazel-testlogs/apple/AxoPhone/AxoPhoneUITests/test.outputs
baselines=$root/apple/AxoPhone/Snapshots/Phone

work=$(mktemp -d "${TMPDIR:-/tmp}/axo-snapshots.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ -d "$outputs/snapshots" ]]; then
  cp "$outputs"/snapshots/*.png "$work"/ 2>/dev/null || true
elif [[ -f "$outputs/outputs.zip" ]]; then
  unzip -q -j -o "$outputs/outputs.zip" 'snapshots/*.png' -d "$work" 2>/dev/null || true
fi

shopt -s nullglob
taken=("$work"/*.png)
if [[ ${#taken[@]} -eq 0 ]]; then
  echo "No screenshots from the phone UI tests; run them first:" >&2
  echo "  bazel test //apple/AxoPhone:AxoPhoneUITests --test_filter=AxoPhoneUITests/testVisual" >&2
  exit 1
fi
mkdir -p "$baselines"
for png in "${taken[@]}"; do
  cp "$png" "$baselines/"
  echo "recorded $(basename "$png")"
done
echo "Review with: git diff -- apple/AxoPhone/Snapshots"
