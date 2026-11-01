#!/usr/bin/env bash
# Writes rust-project.json, for rust-analyzer, as `bazel run @rules_rust//tools/rust_analyzer:gen_rust_project`
# does, from a build action. gen_rust_project runs Bazel itself; it gets an output base of its own,
# so it does not wait on this build. It never fails the build (RFD0021).
set -uo pipefail

gen=$PWD/$1 workspace=$2 bazel=$3 home=$4 output_base=$5 status=$PWD/$6 log=$PWD/$7

export HOME=$home
export PATH="$(dirname "$bazel"):/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -z "$bazel" ]]; then
  echo "rust-project.json: not generated: no bazel on PATH" > "$status"
  : > "$log"
  exit 0
fi

if "$gen" --workspace "$workspace" --output-base "$output_base" --bazel "$bazel" //crates/... > "$log" 2>&1; then
  echo "rust-project.json: current, for rust-analyzer" > "$status"
else
  echo "rust-project.json: not generated; see bazel-bin/bazel/rust/rust_project.log" > "$status"
fi
exit 0
