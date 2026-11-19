#!/bin/bash
# .bazelrc cannot read config.json, so it repeats apple.macos_min for the targets no app
# transitions (swift_test, axod on its own). This test keeps the two equal (RFD0021).
set -euo pipefail
expected="$1"
bazelrc="$2"
if ! grep -Fqx -- "build --enable_platform_specific_config" "$bazelrc"; then
  echo ".bazelrc must enable platform-specific configuration so macOS keeps its minimum OS" >&2
  exit 1
fi
if ! grep -Fqx -- "build:macos --macos_minimum_os=$expected" "$bazelrc"; then
  echo ".bazelrc must say 'build:macos --macos_minimum_os=$expected', as config.json's apple.macos_min does" >&2
  exit 1
fi
if grep -Eq -- '^build[[:space:]]+--macos_minimum_os=' "$bazelrc"; then
  echo "The macOS minimum OS must not become a global Linux/Windows build option" >&2
  exit 1
fi
