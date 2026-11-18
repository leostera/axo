#!/bin/bash
set -euo pipefail
# Feynman's checker uses Bun.hash. This explicit owned-Mac gate fails rather than silently skips.
readonly bun=/opt/homebrew/bin/bun
[[ -x "$bun" ]] || { echo 'Feynman push gate requires the installed Bun runtime' >&2; exit 1; }
cd "$TEST_SRCDIR/$TEST_WORKSPACE/specs"
exec "$bun" run ./check-push.ts
