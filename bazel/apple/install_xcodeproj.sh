#!/usr/bin/env bash
# Generates apple/Axo.xcodeproj as `bazel run //apple:xcodeproj` does, from a build action: the
# rules_xcodeproj runner runs its own Bazel, in its own output base, so it does not wait on this
# one. It never fails the build; the status line says what happened (RFD0021).
set -uo pipefail

runner=$PWD/$1 workspace=$2 bazel=$3 home=$4 status=$PWD/$5 log=$PWD/$6

export BUILD_WORKSPACE_DIRECTORY=$workspace
export HOME=$home
export PATH="$(dirname "$bazel"):/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -z "$bazel" ]]; then
  echo "Axo.xcodeproj: not generated: no bazel on PATH" > "$status"
  : > "$log"
  exit 0
fi

# The runner reads its files from its runfiles, as under bazel run.
cd "$runner.runfiles/_main" || exit 1
if "$runner" > "$log" 2>&1; then
  echo "Axo.xcodeproj: apple/Axo.xcodeproj is current" > "$status"
else
  echo "Axo.xcodeproj: not generated; see bazel-bin/apple/xcodeproj_install.log" > "$status"
fi
exit 0
