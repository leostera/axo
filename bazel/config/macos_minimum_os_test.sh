#!/bin/bash
# .bazelrc cannot read config.json, so it repeats apple.macos_min for the targets no app
# transitions (swift_test, axod on its own). This test keeps the two equal (RFD0021).
set -euo pipefail
expected="$1"
bazelrc="$2"
if ! grep -qx -- "build --macos_minimum_os=$expected" "$bazelrc"; then
  echo ".bazelrc must say 'build --macos_minimum_os=$expected', as config.json's apple.macos_min does" >&2
  exit 1
fi
