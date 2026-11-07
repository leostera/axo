#!/usr/bin/env bash
# Line coverage of axod's Rust code from every test that exercises it:
#
#   1. the crates' own tests (`bazel coverage`, test targets instrumented too, since a crate's
#      `rust_test` compiles its sources itself);
#   2. the black-box tests that drive the real `axod` binary over its socket (`//crates/axod:*`);
#   3. the account Worker's end-to-end tests that drive the real binary through the cloud
#      (`packages/axo-api-worker`, `test:relay`), which are the only tests of the relay's paths.
#
# For 2 and 3 the binary is built instrumented and writes one profile per process.
#
# Usage: bazel/coverage/axod-coverage.sh [--no-worker] [output directory, default /tmp/axod-coverage]
# Writes axod.lcov (everything merged) and prints a per-file summary, least covered first.
set -euo pipefail

worker=1
if [[ "${1:-}" == "--no-worker" ]]; then worker=0; shift; fi
out=${1:-/tmp/axod-coverage}
root=$(git rev-parse --show-toplevel)
cd "$root"

crates='//crates/axo-server,//crates/axo-relay,//crates/axo-ipc,//crates/axo-agent,//crates/axo-store,//crates/axo-panes,//crates/axo-pty,//crates/axo-protocol,//crates/axod'
rm -rf "$out" && mkdir -p "$out/profiles"

tools="$(bazel info output_base)/external/rules_rust++rust+rust_macos_aarch64__aarch64-apple-darwin__stable_tools/lib/rustlib/aarch64-apple-darwin/bin"
[[ -x "$tools/llvm-profdata" ]] || { echo "llvm-profdata not found in $tools" >&2; exit 1; }

echo "== 1. crate tests"
bazel coverage //crates/axo-server/... //crates/axo-relay/... //crates/axo-ipc/... //crates/axo-agent/... \
  //crates/axo-store/... //crates/axo-panes/... //crates/axo-pty/... //crates/axo-protocol/... \
  --nocache_test_results --instrument_test_targets --combined_report=lcov \
  --instrumentation_filter="$crates" --test_tag_filters=-manual 2>&1 | grep -E '^//|Executed|FAILED' || true
cp bazel-out/_coverage/_coverage_report.dat "$out/units.lcov" && chmod u+w "$out/units.lcov"

echo "== 2. the binary, instrumented"
bazel build //crates/axod:axod --collect_code_coverage --instrumentation_filter="$crates" 2>&1 | tail -1
binary="$out/axod"
cp "$(bazel cquery --collect_code_coverage --instrumentation_filter="$crates" --output=files //crates/axod:axod 2>/dev/null)" "$binary"
chmod u+w "$binary"
export LLVM_PROFILE_FILE="$out/profiles/axod-%p-%m.profraw"

echo "== 3. black-box tests of the binary"
bazel test //crates/axod:all --nocache_test_results --test_tag_filters=-manual \
  --test_env=AXOD_BINARY="$binary" --test_env=LLVM_PROFILE_FILE="$LLVM_PROFILE_FILE" \
  --sandbox_writable_path="$out/profiles" 2>&1 | grep -E '^//|Executed|FAILED' || true

if (( worker )); then
  echo "== 4. the Worker's end-to-end tests through the cloud"
  (cd packages/axo-api-worker && AXOD_BINARY="$binary" npx tsx --test --test-concurrency=1 \
    tests/axod-relay.test.ts tests/phone-path.test.ts tests/connections-e2e.test.ts tests/axod-peers.test.ts \
    tests/attachments-e2e.test.ts tests/elicitations-e2e.test.ts 2>&1 | grep -E '^ℹ (pass|fail)|^✖' || true)
fi

echo "== merging"
shopt -s nullglob
profiles=("$out"/profiles/*.profraw)
if (( ${#profiles[@]} )); then
  "$tools/llvm-profdata" merge -sparse "${profiles[@]}" -o "$out/axod.profdata"
  "$tools/llvm-cov" export -format=lcov -instr-profile="$out/axod.profdata" "$binary" \
    -ignore-filename-regex='(external|rustc|\.cargo)/' > "$out/binary.lcov"
fi
python3 "$root/bazel/coverage/merge_lcov.py" "$root" "$out/axod.lcov" "$out/units.lcov" ${profiles:+"$out/binary.lcov"}
