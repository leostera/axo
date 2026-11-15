# AxoDesktop — native Linux workbench (in progress)

A Rust/GTK4 window embedding the **real pinned Ghostty GTK terminal surface**, its VT engine, renderer, fonts and native input machinery. Not GNOME VTE, a browser, or a home-grown text renderer.

The first local workbench has a compact Session sidebar, selected Session, real Pi/terminal panes from the daemon's persisted right/down layout, manual catalog refresh, replay/input and resize. Switching Sessions or closing the window detaches; children keep running. It uses the shared Rust client, not a CLI subprocess or separate backend. This is **not yet Mac feature/visual parity**: creation, dormant Pi wake, live event/reconnect coordination, layout writes, archive/close, grouping and palette remain pending. Native settings now expose daemon-owned shell/agent commands and idle Pi limits; appearance, power, grouping and remote-access settings remain pending. Native title/pane chrome and fixed terminal defaults are still provisional.

## Build and run

Build on Linux with the repository's Bazel toolchain. Native dependencies include GTK4/libadwaita development files, EGL/OpenGL/epoxy, Wayland/X11 headers, blueprint-compiler, glib-compile-resources and xmllint. Ubuntu packages include `libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev libepoxy-dev libegl-dev libwayland-dev libxkbcommon-dev blueprint-compiler libxml2-utils`. When building the daemon too, include its dependencies from [`linux/README.md`](../README.md).

```sh
bazel build //linux/AxoDesktop:AxoDesktop
# Existing local Sessions on an explicitly selected candidate daemon:
bazel run //linux/AxoDesktop:run -- --socket /path/to/candidate/server/axod.sock
# Explicit single-shell development view:
bazel run //linux/AxoDesktop:run -- \
  --attach-socket /path/to/candidate/server/attach.sock --shell 105
# Separate standalone development mode, not an attachment fallback:
bazel run //linux/AxoDesktop:run -- --command '/bin/sh'
bazel test //linux/AxoDesktop:unit_tests //crates/axo-client:test //crates/axo-pty:axo_pty_tests
```

**Attachment requires snapshot-capable protocol v3**, implemented by the candidate daemon ([RFD0055](../../docs/rfds/RFD0055-terminal-snapshot-grid.md)). An older daemon's refusal is shown; no guessed-grid downgrade or local-shell fallback occurs. The candidate server keeps v2 unchanged for shipped Mac/peer clients. Do not install/restart a paired daemon just to try this UI: use an isolated daemon first; deployment is a separate approved operation.

The `run` target resolves process-local resources/libraries from Bazel runfiles. This is not an installer or service. The prototype uses `dev.leostera.AxoDesktop.Prototype` and does not join a running Ghostty app. Rootless development prefixes can be supplied through `PKG_CONFIG_PATH`, `PATH`, `PYTHONPATH` and `XDG_DATA_DIRS` in repository-rule/build-script environments; project files contain no machine-specific prefix.

## Settings

Open **Settings…** from the sidebar or press **Ctrl+,**. General shows daemon status
and the full shell command; Sessions exposes idle timeout/count; Agent exposes the
full agent command. Changes go through shared `axo-client` configuration methods,
with daemon-side parsing and persistence. Commands affect new/restarted processes;
settings never restart the daemon or existing shells/Pi.

Each field has explicit Save. Opening settings never writes, reopening presents the
same window without losing drafts, and Reload values explicitly discards drafts.
Invalid input stays editable. An unconfirmed write disables further saves until a
read reconciles the real value; writes are never automatically retried. Closing
settings or the app cancels UI delivery, not an already-dispatched daemon write.

## Terminal ownership

- `axo-pty::attach` owns the shared v2/v3 wire implementation. v3 supplies the exact grid used to generate its replay, independent of later PTY resizes.
- `axo-client` owns the shared bounded request/event transport also used by the CLI. `LocalCatalog` binds unique pane identities and layouts to their owning Session and refuses relative advertised sockets. `src/workbench.rs` owns only GTK presentation/selection; catalog reads run off-thread with a deadline and do not wake dormant Pi or mutate the catalog.
- `src/task.rs` owns one bounded worker result and cancel-safe GTK delivery. `src/attachment.rs` opens/reads the bounded replay off the GTK thread. Dropping its task removes the delivery callback and closes undelivered attachments; a late worker cannot install a view that was closed.
- `src/ghostty.rs` owns the private, main-thread-only bridge. Widgets retain their engine and immutable prepared attachment through GObject finalization, including before realize.
- `native/bridge.zig` hosts Ghostty's existing GTK Application/Surface classes with supplied prototype defaults. The GTK-only patch initializes at the captured grid and parses the bounded canonical replay during native surface creation, before live I/O threads and actual-viewport resize. No socket I/O runs on the GTK thread. Large-replay initialization latency has not been characterized.
- Ghostty reads output from the attachment socket, **never from the PTY master**. Input, termios queries and host-controlled viewport changes use the master without changing its shared file-status flags. Closing a surface stops its reader and releases duplicates, not the daemon's child process.
- The Rust host owns app/window lifetime: a temporary zero-surface state during catalog load or Session switching is not quit. App-level quit/unrealize also cancels tasks and releases views. Teardown rejects live widgets rather than freeing renderer state beneath them. The Apple XCFramework recipe/patch selection is unchanged; the GTK bridge is a private pinned API, not an upstream stable embedding ABI.

## Controls and parity limits

Human selection/copy/paste uses Ghostty (`Ctrl+Shift+A/C/V`). Output-driven clipboard reads/writes, automatic/OSC links and the inherited Ghostty context menu are restricted until the Axo policy/UI adapters exist. Default Ghostty config files are not loaded or created. Fixed spike font/colors and copy-on-select behavior do not yet match Mac preferences.

The target UI is Axo's compact Session sidebar, full-height panes, split layouts, palette and focus/navigation, with native Linux conventions. [RFD0054](../../docs/rfds/RFD0054-linux-desktop.md) maps the Mac features and shared Rust boundaries. No new session database, relay backend, CLI wrapper or privileged approval mechanism belongs in this GTK shell.

## Owned desktop acceptance

Extra tools: Xvfb, Openbox, xauth, xdotool, system Python GI and GTK/GdkPixbuf/AT-SPI introspection. Tests use a private HOME, X server, D-Bus and runtime/data directories; they never read or drive the real desktop. Supply the built Ghostty runtime's resource/library paths:

```sh
export GHOSTTY_RESOURCES_DIR=/path/to/ghostty-runtime/share/ghostty
export LD_LIBRARY_PATH=/path/to/ghostty-runtime/lib
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop

# Build the candidate axod with its intended CPU/CUDA repository options first.
AXOD_BINARY="$PWD/bazel-bin/crates/axod/axod" \
AXO_DESKTOP_SMOKE_DRIVER="$PWD/linux/AxoDesktop/tests/attach_drive.py" \
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop

AXOD_BINARY="$PWD/bazel-bin/crates/axod/axod" \
AXO_DESKTOP_SMOKE_DRIVER="$PWD/linux/AxoDesktop/tests/workbench_drive.py" \
linux/AxoDesktop/tests/smoke.sh bazel-bin/linux/AxoDesktop/AxoDesktop
```

The standalone test checks actual terminal-color pixels, PTY input, grid/child SIGWINCH, child exit, clean shutdown, unrealized widget lifetime, no Ghostty config creation and no open/read of an existing config canary (inotify).

The attached test starts a real **isolated daemon** and an owned PTY fixture. It checks unchanged v2 framing, v3 replay generated before the view exists, copied long-line text surviving initial grid changes, actual pixels before/after reopening, input, matching resize/SIGWINCH, child/output-pump survival while detached, refusal without fallback and pending-handshake cancellation. Shared Rust tests separately simulate a PTY resize between snapshot capture and client receipt.

The `settings_drive.py` driver checks Ctrl+, singleton/draft preservation, no writes
on load, all four persisted settings, server rejection/canonical values, no process
restart, close with settings open, and lost-acknowledgement reload without retry.
It uses an owned daemon plus a local protocol fixture; add GDK3 introspection for
its owned-desktop screenshot.

The workbench driver checks semantic AT-SPI sidebar selection A/B/A, two real rendered Pi/terminal PTYs, persisted right/down layout and ratio, keyboard routing, matching kernel grids, multi-pane resize, catalog refresh discovering a new Session without changing selection, child survival and clean teardown. It also rejects termios-query failures (the output socket is not a tty).

Artifacts are retained in the reported private temporary directory. Diagnostic `--snapshot`/`--diagnostics` flags are optional; snapshots contain this window's terminal content and must not be committed from real Sessions.

Current acceptance uses Ubuntu 26.04/x86-64, GTK 4.22.4, libadwaita 1.9.1 and software OpenGL under Xvfb. It is not a portable release floor, native Wayland/hardware-GPU acceptance, exhaustive terminal/IME/accessibility parity, a persistent installation, or a completed Linux privileged-client trust design.
