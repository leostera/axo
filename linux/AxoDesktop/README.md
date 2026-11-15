# AxoDesktop — native Linux terminal (in progress)

A Rust/GTK4 window embedding the **real pinned Ghostty GTK terminal surface**, its VT engine, renderer, fonts and native input machinery. Not GNOME VTE, a browser, or a home-grown text renderer.

The candidate can attach to an existing daemon-owned shell with replay, live output, keyboard input and resize. Closing the view detaches; the shell keeps running. It is **not yet the Mac-style Session/pane workbench**. The current header/single-terminal layout is scaffolding, not the final UI.

## Build and run

Build on Linux with the repository's Bazel toolchain. Native dependencies include GTK4/libadwaita development files, EGL/OpenGL/epoxy, Wayland/X11 headers, blueprint-compiler, glib-compile-resources and xmllint. Ubuntu packages include `libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev libepoxy-dev libegl-dev libwayland-dev libxkbcommon-dev blueprint-compiler libxml2-utils`. When building the daemon too, include its dependencies from [`linux/README.md`](../README.md).

```sh
bazel build //linux/AxoDesktop:AxoDesktop
# Explicit existing shell on a candidate daemon:
bazel run //linux/AxoDesktop:run -- \
  --attach-socket /path/to/candidate/server/attach.sock --shell 105
# Separate standalone development mode, not an attachment fallback:
bazel run //linux/AxoDesktop:run -- --command '/bin/sh'
bazel test //linux/AxoDesktop:unit_tests //crates/axo-pty:axo_pty_tests
```

**Attachment requires snapshot-capable protocol v3**, implemented by the candidate daemon ([RFD0055](../../docs/rfds/RFD0055-terminal-snapshot-grid.md)). An older daemon's refusal is shown; no guessed-grid downgrade or local-shell fallback occurs. The candidate server keeps v2 unchanged for shipped Mac/peer clients. Do not install/restart a paired daemon just to try this UI: use an isolated daemon first; deployment is a separate approved operation.

The `run` target resolves process-local resources/libraries from Bazel runfiles. This is not an installer or service. The prototype uses `dev.leostera.AxoDesktop.Prototype` and does not join a running Ghostty app. Rootless development prefixes can be supplied through `PKG_CONFIG_PATH`, `PATH`, `PYTHONPATH` and `XDG_DATA_DIRS` in repository-rule/build-script environments; project files contain no machine-specific prefix.

## Terminal ownership

- `axo-pty::attach` owns the shared v2/v3 wire implementation. v3 supplies the exact grid used to generate its replay, independent of later PTY resizes.
- `src/attachment.rs` opens/reads the bounded replay off the GTK thread. Dropping its task removes the delivery callback and closes undelivered attachments; a late worker cannot install a view that was closed.
- `src/ghostty.rs` owns the private, main-thread-only bridge. Widgets retain their engine and immutable prepared attachment through GObject finalization, including before realize.
- `native/bridge.zig` hosts Ghostty's existing GTK Application/Surface classes with supplied prototype defaults. The GTK-only patch initializes at the captured grid and parses the bounded canonical replay during native surface creation, before live I/O threads and actual-viewport resize. No socket I/O runs on the GTK thread. Large-replay initialization latency has not been characterized.
- Ghostty reads the attachment socket, **never the PTY master**. Input and host-controlled viewport changes use the master without changing its shared file-status flags. Closing a surface stops its reader and releases duplicates, not the daemon's child process.
- Teardown rejects live widgets rather than freeing renderer state beneath them. The Apple XCFramework recipe/patch selection is unchanged; the GTK bridge is a private pinned API, not an upstream stable embedding ABI.

## Controls and parity limits

Human selection/copy/paste uses Ghostty (`Ctrl+Shift+A/C/V`). Output-driven clipboard reads/writes, automatic/OSC links and the inherited Ghostty context menu are restricted until the Axo policy/UI adapters exist. Default Ghostty config files are not loaded or created. Fixed spike font/colors and copy-on-select behavior do not yet match Mac preferences.

The target UI is Axo's compact Session sidebar, full-height panes, split layouts, palette and focus/navigation, with native Linux conventions. [RFD0054](../../docs/rfds/RFD0054-linux-desktop.md) maps the Mac features and shared Rust boundaries. No new session database, relay backend, CLI wrapper or privileged approval mechanism belongs in this GTK shell.

## Owned desktop acceptance

Extra tools: Xvfb, Openbox, xauth, xdotool, system Python GI and GTK/GdkPixbuf introspection. Tests use a private HOME, X server, D-Bus and runtime/data directories; they never read or drive the real desktop. Supply the built Ghostty runtime's resource/library paths:

```sh
export GHOSTTY_RESOURCES_DIR=/path/to/ghostty-runtime/share/ghostty
export LD_LIBRARY_PATH=/path/to/ghostty-runtime/lib
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop

# Build the candidate axod with its intended CPU/CUDA repository options first.
AXOD_BINARY="$PWD/bazel-bin/crates/axod/axod" \
AXO_DESKTOP_SMOKE_DRIVER="$PWD/linux/AxoDesktop/tests/attach_drive.py" \
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop
```

The standalone test checks actual terminal-color pixels, PTY input, grid/child SIGWINCH, child exit, clean shutdown, unrealized widget lifetime, no Ghostty config creation and no open/read of an existing config canary (inotify).

The attached test starts a real **isolated daemon** and an owned PTY fixture. It checks unchanged v2 framing, v3 replay generated before the view exists, copied long-line text surviving initial grid changes, actual pixels before/after reopening, input, matching resize/SIGWINCH, child/output-pump survival while detached, refusal without fallback and pending-handshake cancellation. Shared Rust tests separately simulate a PTY resize between snapshot capture and client receipt.

Artifacts are retained in the reported private temporary directory. Diagnostic `--snapshot`/`--diagnostics` flags are optional; snapshots contain this window's terminal content and must not be committed from real Sessions.

Current acceptance uses Ubuntu 26.04/x86-64, GTK 4.22.4, libadwaita 1.9.1 and software OpenGL under Xvfb. It is not a portable release floor, native Wayland/hardware-GPU acceptance, exhaustive terminal/IME/accessibility parity, a persistent installation, or a completed Linux privileged-client trust design.
