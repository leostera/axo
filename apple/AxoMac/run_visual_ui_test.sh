#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Axo visual UI Bazel test: %s\n' "$1" >&2
  exit 1
}

resolve_runfile() {
  local relative_path="$1"
  local runfiles_root="${RUNFILES_DIR:-${TEST_SRCDIR:-}}"
  if [[ -n "$runfiles_root" && -e "$runfiles_root/$relative_path" ]]; then
    printf '%s\n' "$runfiles_root/$relative_path"
    return 0
  fi
  if [[ -n "${RUNFILES_MANIFEST_FILE:-}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
    awk -v wanted="$relative_path" '
      index($0, wanted " ") == 1 {
        print substr($0, length(wanted) + 2)
        exit
      }
    ' "$RUNFILES_MANIFEST_FILE"
    return 0
  fi
  return 1
}

stop_daemon() {
  [[ -n "${daemon_pid:-}" ]] || return 0
  if kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 60; attempt++)); do
      kill -0 "$daemon_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$daemon_pid" 2>/dev/null; then
      kill -KILL "$daemon_pid" 2>/dev/null || true
    fi
  fi
  wait "$daemon_pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  stop_daemon
  if [[ -n "${root:-}" && -d "$root" ]]; then
    if [[ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
      [[ ! -f "$root/server/stderr.log" ]] || cp "$root/server/stderr.log" "$TEST_UNDECLARED_OUTPUTS_DIR/axod.log"
      [[ ! -f "$root/axod-launch.log" ]] || cp "$root/axod-launch.log" "$TEST_UNDECLARED_OUTPUTS_DIR/axod-launch.log"
    fi
    case "$root" in
      "${tmp_parent:-/tmp}"/a.*) rm -rf "$root" ;;
      *) printf 'Refusing to remove unexpected visual-test root: %s\n' "$root" >&2 ;;
    esac
  fi
  exit "$status"
}

: "${TEST_SRCDIR:?Bazel did not set TEST_SRCDIR}"
: "${TEST_WORKSPACE:?Bazel did not set TEST_WORKSPACE}"
: "${TEST_UNDECLARED_OUTPUTS_DIR:?Bazel did not provide a test output directory}"
: "${AXO_UI_AXOD_RUNFILE:?Bazel did not provide the axod runfile}"

workspace_runfiles="$TEST_SRCDIR/$TEST_WORKSPACE"
[[ -d "$workspace_runfiles" ]] || fail "test workspace runfiles are missing: $workspace_runfiles"

module_file=$(resolve_runfile "$AXO_WORKSPACE_MODULE") || fail "could not resolve workspace MODULE.bazel"
while [[ -L "$module_file" ]]; do
  module_target=$(readlink "$module_file")
  if [[ "$module_target" = /* ]]; then
    module_file="$module_target"
  else
    module_file="$(dirname "$module_file")/$module_target"
  fi
done
workspace_root=$(cd "$(dirname "$module_file")" && pwd -P)
xcodeproj_runner=$(resolve_runfile "$AXO_XCODEPROJ_RUNNER") || fail "could not resolve the Bazel Xcode-project runner"
axod=$(resolve_runfile "$AXO_UI_AXOD_RUNFILE") || fail "could not resolve the isolated axod binary"
[[ -x "$axod" ]] || fail "the isolated axod binary is not executable: $axod"
npm --prefix "$workspace_root/packages/pi-axo" run build
pi_executable=$(command -v pi || true)
[[ -n "$pi_executable" && -x "$pi_executable" ]] || fail "Pi CLI is required for the isolated Workspace E2E"

[[ -f "$workspace_runfiles/apple/AxoMac/xcodeproj_execution_root_file" ]] ||
  fail "Xcode-project runner support files are missing from runfiles"
[[ -f "$workspace_root/apple/AxoMac/BUILD.bazel" ]] ||
  fail "resolved workspace root is not the Axo source tree: $workspace_root"

# The XCUITest runner is sandboxed: both it and the external daemon must use
# its container temp directory for AF_UNIX access. Keep the child path short.
tmp_parent="$HOME/Library/Containers/dev.leostera.axo.vt.xctrunner/Data/tmp"
mkdir -p "$tmp_parent"
root=$(mktemp -d "$tmp_parent/a.XXXXXX")
chmod 700 "$root"
mkdir -m 700 "$root/server" "$root/home" "$root/tmp" "$root/control"
socket="$root/s"
[[ ${#socket} -le 103 ]] || fail "test socket path exceeds the AF_UNIX limit: $socket"

export AXO_UI_TEST_ROOT="$root"
export AXO_UI_TEST_SOCKET="$socket"
export AXO_UI_TEST_CONTROL_DIR="$root/control"
daemon_pid=
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

env -i \
  HOME="$root/home" \
  TMPDIR="$root/tmp" \
  PATH="$(dirname "$pi_executable"):/usr/bin:/bin:/usr/sbin:/sbin" \
  PI_OFFLINE=1 \
  AXO_PI_BRIDGE_DEBUG=1 \
  AXO_PI_EXECUTABLE="$pi_executable" \
  AXO_PI_EXTENSION_PATH="$workspace_root/packages/pi-axo/dist/index.js" \
  SHELL=/bin/zsh \
  USER="${USER:-$(id -un)}" \
  LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
  LANG="${LANG:-en_US.UTF-8}" \
  "$axod" --socket "$socket" --server-dir "$root/server" \
  >"$root/axod-launch.log" 2>&1 &
daemon_pid=$!

for ((attempt = 0; attempt < 160; attempt++)); do
  [[ ! -S "$socket" ]] || break
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    wait "$daemon_pid" || true
    daemon_pid=
    [[ ! -f "$root/server/stderr.log" ]] || cat "$root/server/stderr.log" >&2
    [[ ! -f "$root/axod-launch.log" ]] || cat "$root/axod-launch.log" >&2
    fail "isolated axod exited before creating its socket"
  fi
  sleep 0.05
done
[[ -S "$socket" ]] || fail "isolated axod did not create its socket within eight seconds"

# The rules_xcodeproj runner reads its support files from the runfiles cwd,
# then uses BUILD_WORKSPACE_DIRECTORY for the real workspace and generated project.
cd "$workspace_runfiles"
export BUILD_WORKSPACE_DIRECTORY="$workspace_root"
"$xcodeproj_runner"

result_bundle="$TEST_UNDECLARED_OUTPUTS_DIR/AxoVisualUITests.xcresult"
project="$workspace_root/apple/AxoMac/AxoMac.xcodeproj"
[[ -d "$project" ]] || fail "the generated Xcode project is missing: $project"
scheme_file="$project/xcshareddata/xcschemes/AxoVisualUITests.xcscheme"
[[ -f "$scheme_file" ]] || fail "the generated Xcode UI-test scheme is missing: $scheme_file"
python3 - "$scheme_file" "$root" <<'PY'
import re
import sys
from xml.sax.saxutils import escape

scheme_path, test_root = sys.argv[1:]
with open(scheme_path, encoding="utf-8") as scheme_file:
    scheme = scheme_file.read()
start = scheme.index("<TestAction")
end = scheme.index("</TestAction>", start)
test_action = scheme[start:end]
test_action = re.sub(
    r'\s*<EnvironmentVariable\b(?=[^>]*\bkey\s*=\s*"AXO_UI_TEST_ROOT")[^>]*>.*?</EnvironmentVariable>',
    "",
    test_action,
    flags=re.DOTALL,
)
marker = "      </EnvironmentVariables>"
if marker not in test_action:
    raise SystemExit("The Xcode scheme has no TestAction EnvironmentVariables block")
entry = (
    "         <EnvironmentVariable\n"
    '            key = "AXO_UI_TEST_ROOT"\n'
    f'            value = "{escape(test_root).replace(chr(34), "&quot;")}"\n'
    '            isEnabled = "YES">\n'
    "         </EnvironmentVariable>\n"
)
test_action = test_action.replace(marker, entry + marker, 1)
scheme = scheme[:start] + test_action + scheme[end:]
with open(scheme_path, "w", encoding="utf-8") as scheme_file:
    scheme_file.write(scheme)
PY

printf 'AXO_UI_XCRESULT=%s\n' "$result_bundle"
xcodebuild_log="$TEST_UNDECLARED_OUTPUTS_DIR/xcodebuild.log"
test_filter_args=()
if [[ -n "${AXO_UI_TEST_ONLY:-}" ]]; then
  test_filter_args=(-only-testing:"AxoVisualUITests/AxoVisualUITests/${AXO_UI_TEST_ONLY}")
fi
if xcodebuild test \
  -project "$project" \
  -scheme AxoVisualUITests \
  -destination "${AXO_UI_TEST_DESTINATION:-platform=macOS}" \
  -parallel-testing-enabled NO \
  "${test_filter_args[@]}" \
  -resultBundlePath "$result_bundle" >"$xcodebuild_log" 2>&1
then
  tail -n 80 "$xcodebuild_log"
else
  status=$?
  tail -n 160 "$xcodebuild_log" >&2
  exit "$status"
fi
