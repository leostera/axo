#!/bin/sh
# Run from any directory on the Linux host. Does not install or register a daemon.
set -eu
cd "$(dirname "$0")/.."
bazel build //linux:runtime --jobs=8
# Linux inotify instances are shared per user. Keep integration daemons serialized.
bazel test \
  //crates/axo-protocol:axo_protocol_tests \
  //crates/axo-ipc:axo_ipc_tests \
  //crates/axo-seal:axo_seal_tests \
  //crates/axo-signin:axo_signin_tests \
  //crates/axo-pty:axo_pty_tests \
  //crates/axo-agent:axo_agent_tests \
  //crates/axo-store:axo_store_tests \
  //crates/axo-relay:axo_relay_tests \
  //crates/axo-computer:axo_computer_tests \
  //crates/axod-infer:axod_infer_tests \
  //crates/axod:conformance_daemon \
  //crates/axod:conformance_sessions \
  //crates/axod:conformance_account \
  //crates/axod:conformance_elicitations \
  //crates/axod:conformance_relay \
  --jobs=8 --local_test_jobs=1 --test_env=RUST_TEST_THREADS=1 --test_timeout=120
staging=$(mktemp -d /tmp/axo-linux-runtime.XXXXXX)
trap 'rm -rf "$staging"' EXIT
tar -xzf bazel-bin/linux/axo-linux.tar.gz -C "$staging"
python3 linux/smoke.py --bundled-resources "$staging/axod"
