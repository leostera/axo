#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

if [[ -n ${AXOD_BUILD_NUMBER:-} ]]; then
  build_number=$AXOD_BUILD_NUMBER
else
  build_number=$(tr -d '\r\n' < "$root/BUILD_NUMBER")
fi

if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "AXOD_BUILD_NUMBER must be a positive canonical decimal integer" >&2
  exit 1
fi

printf 'STABLE_BUILD_NUMBER %s\n' "$build_number"
