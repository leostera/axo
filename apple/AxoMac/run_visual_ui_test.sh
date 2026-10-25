#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Axo visual UI Bazel test: %s\n' "$1" >&2
  exit 1
}

check_no_axo_frontend() {
  local pids
  pids=$(/usr/bin/pgrep -x Axo || true)
  [[ -z "$pids" ]] || fail "refusing to launch UI tests while Axo frontend PID(s) are running: ${pids//$'\n'/, }; close them manually first"
}

check_no_axo_frontend

all_test_cases=(
  testKittyKeyboardNegotiationEncodesReturnAndShiftEnter
  testFocusOnlyClickIsNotReportedToTerminalMouseMode
  testTerminalScrollWheelReachesMouseReportingChild
  testTerminalContextMenuRoutesSplitsAndCloseThroughAxo
  testSessionSidebarContextMenuRenamesAndArchives
  testWorkspaceNameFieldReceivesPasteShortcut
  testTerminalAccessibilityExposesVisibleScreenText
  testClipboardReadsRequireApprovalAndRejectDenialOrCancellation
  testClipboardWritesRequireApprovalAndRejectDenialOrCancellation
  testCreateWorkspaceShowsFirstSessionAndPiSurvivesAppCloseAndReopen
  testLaunchSplitCloseExitSessionSelectionAndSurvivingShell
  testCommandPaletteRunsCommandsAndReturnsTypingToTheTerminal
)
test_cases=("${all_test_cases[@]}")
if [[ -n "${AXO_UI_TEST_ONLY:-}" ]]; then
  test_cases=()
  for available_case in "${all_test_cases[@]}"; do
    if [[ "$available_case" == "$AXO_UI_TEST_ONLY" ]]; then
      test_cases=("$available_case")
      break
    fi
  done
  [[ ${#test_cases[@]} -eq 1 ]] || fail "unknown visual UI test case: $AXO_UI_TEST_ONLY"
fi

resolve_runfile() {
  local relative_path="$1"
  local runfiles_root="${RUNFILES_DIR:-${TEST_SRCDIR:-}}"
  if [[ -n "$runfiles_root" && -e "$runfiles_root/$relative_path" ]]; then
    printf '%s\n' "$runfiles_root/$relative_path"
    return 0
  fi
  if [[ -n "${RUNFILES_MANIFEST_FILE:-}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
    local resolved_path
    resolved_path=$(awk -v wanted="$relative_path" '
      index($0, wanted " ") == 1 {
        print substr($0, length(wanted) + 2)
        exit
      }
    ' "$RUNFILES_MANIFEST_FILE") || return 1
    [[ -n "$resolved_path" ]] || return 1
    printf '%s\n' "$resolved_path"
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
  daemon_pid=
}

cleanup_fixture() {
  stop_daemon
  if [[ -n "${root:-}" && -d "$root" ]]; then
    if [[ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
      [[ ! -f "$root/server/stderr.log" ]] || cp "$root/server/stderr.log" "$TEST_UNDECLARED_OUTPUTS_DIR/${current_case:-visual}-axod.log"
      [[ ! -f "$root/axod-launch.log" ]] || cp "$root/axod-launch.log" "$TEST_UNDECLARED_OUTPUTS_DIR/${current_case:-visual}-axod-launch.log"
    fi
    case "$root" in
      "${tmp_parent:-/tmp}"/a.*) rm -rf "$root" ;;
      *) printf 'Refusing to remove unexpected visual-test root: %s\n' "$root" >&2 ;;
    esac
  fi
  root=
  unset AXO_UI_TEST_ROOT AXO_UI_TEST_SOCKET AXO_UI_TEST_CONTROL_DIR
}

wait_for_daemon_socket() {
  local socket="$1"
  local pid="$2"
  local fixture_root="$3"

  for ((attempt = 0; attempt < 160; attempt++)); do
    [[ ! -S "$socket" ]] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      daemon_pid=
      [[ ! -f "$fixture_root/server/stderr.log" ]] || /bin/cat "$fixture_root/server/stderr.log" >&2
      [[ ! -f "$fixture_root/axod-launch.log" ]] || /bin/cat "$fixture_root/axod-launch.log" >&2
      fail "isolated axod exited before creating its socket"
    fi
    sleep 0.05
  done
  [[ -S "$socket" ]] || fail "isolated axod did not create its socket within eight seconds"
}

start_test_fixture() {
  local test_tmp_parent="$1"
  local axod_binary="$2"
  local pi_binary="$3"
  local source_root="$4"

  root=$(mktemp -d "$test_tmp_parent/a.XXXXXX") || fail "could not create an isolated test root"
  chmod 700 "$root" || fail "could not secure the isolated test root"
  mkdir -m 700 "$root/server" "$root/home" "$root/tmp" "$root/control" ||
    fail "could not create isolated Axo test directories"
  local socket="$root/s"
  [[ ${#socket} -le 103 ]] || fail "test socket path exceeds the AF_UNIX limit: $socket"
  export AXO_UI_TEST_ROOT="$root"
  export AXO_UI_TEST_SOCKET="$socket"
  export AXO_UI_TEST_CONTROL_DIR="$root/control"

  env -i \
    HOME="$root/home" \
    TMPDIR="$root/tmp" \
    PATH="$(dirname "$pi_binary"):/usr/bin:/bin:/usr/sbin:/sbin" \
    PI_OFFLINE=1 \
    AXO_PI_BRIDGE_DEBUG=1 \
    AXO_PI_EXECUTABLE="$pi_binary" \
    AXO_PI_EXTENSION_PATH="$source_root/packages/pi-axo/dist/index.js" \
    SHELL=/bin/zsh \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
    LANG="${LANG:-en_US.UTF-8}" \
    "$axod_binary" --socket "$socket" --server-dir "$root/server" \
    >"$root/axod-launch.log" 2>&1 &
  daemon_pid=$!
  wait_for_daemon_socket "$socket" "$daemon_pid" "$root"
}

configure_scheme_for_fixture() {
  local scheme_path="$1"
  local fixture_root="$2"

  if ! python3 - "$scheme_path" "$fixture_root" <<'PY'
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
escaped_root = escape(test_root).replace('"', "&quot;")
entry = (
    "         <EnvironmentVariable\n"
    '            key = "AXO_UI_TEST_ROOT"\n'
    f'            value = "{escaped_root}"\n'
    '            isEnabled = "YES">\n'
    "         </EnvironmentVariable>\n"
)
test_action = test_action.replace(marker, entry + marker, 1)
scheme = scheme[:start] + test_action + scheme[end:]
with open(scheme_path, "w", encoding="utf-8") as scheme_file:
    scheme_file.write(scheme)
PY
  then
    fail "could not set AXO_UI_TEST_ROOT in the generated Xcode scheme"
  fi
}

run_xcodebuild_case() {
  local test_case="$1"
  local project_path="$2"
  local result_bundle="$3"
  local log_path="$4"
  local destination="$5"
  local status=0

  if xcodebuild test \
    -project "$project_path" \
    -scheme AxoVisualUITests \
    -destination "$destination" \
    -parallel-testing-enabled NO \
    -only-testing:"AxoVisualUITests/AxoVisualUITests/${test_case}" \
    -resultBundlePath "$result_bundle" >"$log_path" 2>&1
  then
    has_built_tests=true
    tail -n 70 "$log_path"
  else
    status=$?
    tail -n 140 "$log_path" >&2
  fi
  return "$status"
}

restore_scheme() {
  [[ -z "${scheme_backup:-}" ]] && return 0
  [[ -f "$scheme_backup" ]] || return 1
  [[ -n "${scheme_file:-}" && -f "$scheme_file" ]] || return 1
  cp "$scheme_backup" "$scheme_file"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if ! restore_scheme; then
    printf 'Could not restore the generated Xcode test scheme: %s\n' "${scheme_file:-unknown}" >&2
    status=1
  fi
  cleanup_fixture
  if [[ "$status" -eq 0 && -n "${scheme_backup:-}" ]]; then
    rm -f "$scheme_backup"
  fi
  exit "$status"
}

: "${TEST_SRCDIR:?Bazel did not set TEST_SRCDIR}"
: "${TEST_WORKSPACE:?Bazel did not set TEST_WORKSPACE}"
: "${TEST_UNDECLARED_OUTPUTS_DIR:?Bazel did not provide a test output directory}"
: "${AXO_WORKSPACE_MODULE:?Bazel did not provide the workspace module runfile}"
: "${AXO_XCODEPROJ_RUNNER:?Bazel did not provide the Xcode project runner runfile}"
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
[[ -x "$xcodeproj_runner" ]] || fail "the Xcode-project runner is not executable: $xcodeproj_runner"
axod=$(resolve_runfile "$AXO_UI_AXOD_RUNFILE") || fail "could not resolve the isolated axod binary"
[[ -x "$axod" ]] || fail "the isolated axod binary is not executable: $axod"
npm --prefix "$workspace_root/packages/pi-axo" run build
pi_executable=$(command -v pi || true)
[[ -n "$pi_executable" && -x "$pi_executable" ]] || fail "Pi CLI is required for the isolated Workspace E2E"

[[ -f "$workspace_runfiles/apple/xcodeproj_execution_root_file" ]] ||
  fail "Xcode-project runner support files are missing from runfiles"
[[ -f "$workspace_root/apple/AxoMac/BUILD.bazel" ]] ||
  fail "resolved workspace root is not the Axo source tree: $workspace_root"

# XCUITest runs all selected methods in one runner process. Give every method its own Axod
# database, PTYs, home, and Pi transcript root so tests cannot inherit another method's sessions.
tmp_parent="$HOME/Library/Containers/dev.leostera.axo.vt.xctrunner/Data/tmp"
mkdir -p "$tmp_parent"
root=
daemon_pid=
current_case=
scheme_file=
scheme_backup=
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$workspace_runfiles"
export BUILD_WORKSPACE_DIRECTORY="$workspace_root"
"$xcodeproj_runner"

project="$workspace_root/apple/Axo.xcodeproj"
[[ -d "$project" ]] || fail "the generated Xcode project is missing: $project"
scheme_file="$project/xcshareddata/xcschemes/AxoVisualUITests.xcscheme"
[[ -f "$scheme_file" ]] || fail "the generated Xcode UI-test scheme is missing: $scheme_file"
scheme_backup_candidate=$(mktemp "$TEST_UNDECLARED_OUTPUTS_DIR/.AxoVisualUITests-scheme.XXXXXX")
if ! cp "$scheme_file" "$scheme_backup_candidate"; then
  rm -f "$scheme_backup_candidate"
  fail "could not back up the generated Xcode test scheme"
fi
scheme_backup="$scheme_backup_candidate"

run_test_case() {
  local test_case="$1"
  local result_bundle="$TEST_UNDECLARED_OUTPUTS_DIR/AxoVisualUITests-${test_case}.xcresult"
  local xcodebuild_log="$TEST_UNDECLARED_OUTPUTS_DIR/xcodebuild-${test_case}.log"
  local status=0

  current_case="$test_case"
  check_no_axo_frontend
  start_test_fixture "$tmp_parent" "$axod" "$pi_executable" "$workspace_root"
  configure_scheme_for_fixture "$scheme_file" "$root"
  check_no_axo_frontend

  printf 'AXO_UI_XCRESULT=%s\n' "$result_bundle"
  if run_xcodebuild_case \
    "$test_case" "$project" "$result_bundle" "$xcodebuild_log" \
    "${AXO_UI_TEST_DESTINATION:-platform=macOS}"
  then
    status=0
  else
    status=$?
  fi

  if ! restore_scheme; then
    fail "could not restore the generated Xcode test scheme after $test_case"
  fi
  cleanup_fixture
  current_case=
  return "$status"
}

overall_status=0
for test_case in "${test_cases[@]}"; do
  if ! run_test_case "$test_case"; then
    overall_status=1
  fi
done
exit "$overall_status"
