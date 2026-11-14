# AxoDesktop — Linux native embedding prototype

A Rust/GTK4 window embedding the **real pinned Ghostty GTK terminal widget**: its renderer, fonts, keyboard/IME machinery and terminal I/O, not VTE, an embedded browser or a home-grown text renderer.

This is an isolated technical prototype, **not yet an Axo session client**. It starts a local command/PTY through Ghostty. It does not connect to, restart, install or change the paired `axod`, read Axo credentials, or replicate the Mac app's feature set.

## Architecture

- `src/main.rs`: Rust owns the GTK window, title/header, close lifecycle and optional development diagnostics.
- `src/ghostty.rs`: typed, main-thread-only ownership of the private bridge and native GObject widgets.
- `native/bridge.zig`: a small private ABI around Ghostty's existing GTK Application/Surface classes. Keep its GLib/core event loop and busy-child close confirmation intact.
- `ghostty_gtk_repository.bzl`: build the pinned Ghostty source/toolchain as a GTK library with its resources. Small GTK-only source adjustments enable the existing runtime/dependencies in a shared library and caller-supplied configuration; the Apple XCFramework recipe and patch selection are unchanged.

The native application is currently Ghostty's GTK application subclass, with a unique prototype app ID and explicitly supplied defaults/arguments (no default config-file read or creation). Unsupported application/window keybindings are cleared; terminal copy/paste bindings remain. Rust supplies its own window rather than opening Ghostty's default window. This proves the widget integration; it is not a claim that upstream offers a stable standalone GTK embedding API. The private ABI is deliberately small and pinned.

All GTK/bridge calls stay on the main thread. Rust sinks widget references and destroys its windows/disconnects callbacks before tearing down Ghostty. Widgets retain their Rust engine owner until GObject finalization. The native destructor also refuses to free state while widgets remain (including ones not yet realized), rather than risking use-after-free.

## Build and run

Build on Linux with the repository's Bazel toolchain. Native build requirements include GTK4 development files, libadwaita (at least the pinned source's current blueprint requirement), EGL/OpenGL/epoxy, Wayland/X11 development files, blueprint-compiler, glib-compile-resources, xmllint and the normal Ghostty C/C++ build dependencies. Ubuntu packages include `libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev libepoxy-dev libegl-dev libwayland-dev libxkbcommon-dev blueprint-compiler libxml2-utils`.

```sh
bazel build //linux/AxoDesktop:AxoDesktop
bazel run //linux/AxoDesktop:run
# Explicit standalone local command:
bazel run //linux/AxoDesktop:run -- --command '/bin/sh'
bazel test //linux/AxoDesktop:unit_tests
```

The `run` target sets the process-local Ghostty resources/library locations from Bazel runfiles. It is not an installer or a background service. The prototype deliberately uses its own ID, `dev.leostera.AxoDesktop.Prototype`, rather than joining a running Ghostty instance.

For rootless development, a separately extracted development prefix can be supplied through `PKG_CONFIG_PATH`, `PATH`, `PYTHONPATH` and `XDG_DATA_DIRS` (repository-rule environment and build-script action environment as appropriate). These are developer-machine inputs, not hardcoded project paths or changes to the system's desktop libraries.

## Acceptance smoke

Extra test tools: Xvfb, Openbox, xauth, xdotool, system Python GI and GdkPixbuf introspection. The build has been exercised on Ubuntu 26.04/x86-64 with GTK 4.22.4 and libadwaita 1.9.1; this spike does not declare a supported older-distribution floor. Supply the built runtime's resources/library paths, then:

```sh
GHOSTTY_RESOURCES_DIR=/path/to/ghostty-runtime/share/ghostty \
LD_LIBRARY_PATH=/path/to/ghostty-runtime/lib \
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop
```

The launcher creates a private HOME, X server, D-Bus and runtime/config/data directories. Its owned PTY fixture emits ANSI colors and Unicode; the driver checks:

1. Refusal to free an engine with a live unrealized widget, no Ghostty config creation, and no open/read of an existing config canary (inotify).
2. A Rust-owned GTK window with a ready Ghostty surface.
3. Actual rendered terminal-color pixels in GSK texture readback, not merely a successful widget constructor.
4. Keyboard input reaches the real PTY child.
5. Window resizing changes the native terminal grid and delivers the matching SIGWINCH/size to the child.
6. Child exit and clean widget/engine teardown.

The PNG, diagnostics and logs are retained in the reported private temporary directory for inspection. Only fixture content is captured; the real desktop is never read or driven. Software OpenGL under Xvfb is functional rendering evidence, not a GPU performance claim or native Wayland acceptance.

## Next boundary, before feature replication

The current Mac feature map and shared-core/serial implementation contract are in [RFD0054](../../docs/rfds/RFD0054-linux-desktop.md). The first real-client integration must attach this surface to **daemon-owned PTYs**, preserving `axod` as the sole output reader and using its existing replay/input/resize transport. The current Apple external-I/O patch does not automatically wire those descriptors through the GTK widget. Do not build a second session backend around this prototype's standalone PTY.

Settings, session/workbench UI, pairing, tray, privileged local IPC, release/install lifecycle, accessibility acceptance and multi-window/multi-monitor behavior are not implemented by this spike. Native Wayland and real GNOME behavior require their own tests; the computer-use helper's GNOME 50 restriction is not bypassed here.
