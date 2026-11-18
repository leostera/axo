#!/bin/bash
# Build the manual Rust acceptance target first; this owns an entirely separate desktop.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
gtk_python=${AXO_LINUX_GTK_PYTHON:-/usr/bin/python3}
if [[ ${1:-} != --inside ]]; then
    test_binary=$(realpath "${1:?usage: computer-smoke.sh /path/to/linux_desktop_smoke_test}")
    run=$(mktemp -d)
    chmod 700 "$run"
    # Optional rootless build/test packages, not required by a normal distro install.
    if [[ -n ${AXO_LINUX_DESKTOP_DEPS:-} ]]; then
        export PATH="$AXO_LINUX_DESKTOP_DEPS/usr/bin:$PATH"
        export LD_LIBRARY_PATH="$AXO_LINUX_DESKTOP_DEPS/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export XDG_DATA_DIRS="$AXO_LINUX_DESKTOP_DEPS/usr/share:/usr/local/share:/usr/share"
    fi
    for tool in Xvfb xvfb-run openbox dbus-run-session xauth; do command -v "$tool" >/dev/null; done
    "$gtk_python" -c 'import gi; gi.require_version("Gtk", "4.0")'
    # No inherited real desktop, nested compositor request, session bus or session id.
    if env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u XDG_SESSION_ID \
        -u CUA_WAYLAND_NEST -u CUA_DRIVER_RS_ENABLE_WAYLAND \
        AXO_LINUX_ISOLATED_DESKTOP=1 XDG_RUNTIME_DIR="$run" \
        xvfb-run -a -s '-screen 0 1024x768x24 -nolisten tcp' \
        dbus-run-session -- "$0" --inside "$test_binary" "$run"; then
        rm -rf -- "$run"
    else
        echo "Desktop acceptance failed; private fixture logs retained in $run" >&2
        exit 1
    fi
    exit 0
fi
shift
test_binary=$1
run=$2
export GDK_BACKEND=x11 GTK_A11Y=atspi NO_AT_BRIDGE=0
openbox --sm-disable >"$run/wm.log" 2>&1 &
wm=$!
"$gtk_python" "${AXO_LINUX_FIXTURE_SCRIPT:-$here/computer-fixture.py}" >"$run/fixture.log" 2>&1 &
fixture=$!
cleanup() {
    kill "$fixture" "$wm" 2>/dev/null || true
    wait "$fixture" "$wm" 2>/dev/null || true
}
trap cleanup EXIT
export AXO_LINUX_FIXTURE_PID=$fixture
"$test_binary" --ignored "${AXO_LINUX_TEST_FILTER:-real_linux_desktop_reads_captures_edits_and_checks_nested_lock_state}" --nocapture
