#!/bin/bash
# Uses a private HOME, X server, D-Bus and an owned fixture. Never drives the real desktop.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
binary=$(realpath "${1:?usage: smoke.sh /path/to/AxoDesktop}")
: "${GHOSTTY_RESOURCES_DIR:?point this at the built Ghostty share/ghostty directory}"
if [[ -n ${AXO_DESKTOP_BUILD_DEPS_ROOT:-} ]]; then
    export PATH="$AXO_DESKTOP_BUILD_DEPS_ROOT/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$AXO_DESKTOP_BUILD_DEPS_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export XDG_DATA_DIRS="$AXO_DESKTOP_BUILD_DEPS_ROOT/usr/share:/usr/local/share:/usr/share"
fi
if [[ -n ${AXO_X11_TOOLS_ROOT:-} ]]; then
    export PATH="$AXO_X11_TOOLS_ROOT/usr/bin:$PATH"
    export XDG_DATA_DIRS="$AXO_X11_TOOLS_ROOT/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    export LD_LIBRARY_PATH="$AXO_X11_TOOLS_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
for program in Xvfb xvfb-run openbox dbus-run-session xauth xdotool; do command -v "$program" >/dev/null; done
run=$(mktemp -d /tmp/axo-gtk-prototype.XXXXXX)
chmod 700 "$run"
mkdir -p "$run"/{home,runtime,config,cache,data,state}
chmod 700 "$run/runtime"
set +e
env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u XDG_SESSION_ID -u NOTIFY_SOCKET \
    HOME="$run/home" XDG_RUNTIME_DIR="$run/runtime" XDG_CONFIG_HOME="$run/config" \
    XDG_CACHE_HOME="$run/cache" XDG_DATA_HOME="$run/data" XDG_STATE_HOME="$run/state" \
    GDK_BACKEND=x11 GSK_RENDERER=gl LIBGL_ALWAYS_SOFTWARE=1 GSETTINGS_BACKEND=memory \
    xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' \
    dbus-run-session -- /usr/bin/python3 "$here/drive.py" "$binary" "$run"
status=$?
set -e
echo "Prototype artifacts: $run"
exit "$status"
