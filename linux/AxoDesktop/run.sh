#!/bin/bash
# Bazel launcher: establish only this process's bundled Ghostty resources/libraries.
set -euo pipefail
source "${RUNFILES_DIR:-$0.runfiles}/bazel_tools/tools/bash/runfiles/runfiles.bash"
binary=$(rlocation "$1")
marker=$(rlocation "$2")
shift 2
runtime=$(dirname "$marker")
export GHOSTTY_RESOURCES_DIR="$runtime/share/ghostty"
export LD_LIBRARY_PATH="$runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$binary" "$@"
