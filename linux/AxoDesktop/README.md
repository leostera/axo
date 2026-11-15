# AxoDesktop — native Linux workbench (in progress)

A Rust/GTK4 window embedding the **real pinned Ghostty GTK terminal surface**, its VT engine, renderer, fonts and native input machinery. Not GNOME VTE, a browser, or a home-grown text renderer.

The first local workbench has a compact Session sidebar, selected Session, real Pi/terminal panes from the daemon's persisted right/down layout, manual catalog refresh, replay/input and resize. Switching Sessions or quitting detaches; children keep running. Closing hides the window only when a tray host is confirmed; otherwise it quits. It uses the shared Rust client, not a CLI subprocess or separate backend. This is **not yet Mac feature/visual parity**: creation, dormant Pi wake, live event/reconnect coordination, layout writes, archive/close, grouping and palette remain pending. Native settings now expose daemon-owned shell/agent commands and idle Pi limits; appearance, power, grouping and remote-access settings remain pending. The presentation now follows screenshots of the running Mac app: neutral grouped settings with inline values, a fixed 220px sidebar with 22px Session rows, native drag/window controls and caption-free, full-height panes. This is not a complete Mac visual/behavioral conformance claim.

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

## Presentation

`src/style.rs` styles only Axo-owned windows, not the desktop theme or Ghostty's
renderer. The workbench keeps GTK CSD move/resize behavior and the platform's
window-control order inside the sidebar; the terminal has no full-width titlebar.
The unneeded wordmark and visible pane captions are removed; Pi/terminal groups
retain accessible names. Session rows have the daemon's last-read status, emoji or
native fallback glyph; sleeping Pis stay gray rather than appearing ready. Manual
refresh still controls freshness; there is no fabricated unseen/activity state or
live subscription. Footer actions retain accessible names/tooltips and keyboard
access.

Settings use a 180px icon sidebar with its own native title/close controls, not a
full-width header. Section headings sit outside neutral grouped cards; labels and
values share a row, numeric controls stay compact, and command saves sit at the
card's trailing bottom edge. General has an actual daemon-status row. Scrollable
pages preserve access at smaller sizes; the stable feedback/reload area retains
explicit uncertain-write recovery. Only implemented categories are listed.

Container spacing uses GTK widget margins, not CSS padding, so AT-SPI control
bounds agree with the rendered layout. Stylesheet parse failures fail startup
rather than silently using a partially broken theme. Pending terminal attachments
cannot steal typing focus from an inactive workbench behind Settings.

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

## Tray / status app

Workbench mode exports a native **StatusNotifierItem + DBusMenu** over the session
bus using GIO (no GTK3/VTE shim). Its menu offers Show Axo, Hide Axo, Settings and
Quit, plus daemon connection status. Quit detaches views; it never stops axod or
its children. Standalone development mode keeps its existing window lifecycle.

The watcher must acknowledge registration **and** report a live tray host before
window-close or Hide can hide the workbench. Watcher presence alone is insufficient.
Host presence is rechecked because the standard has no required host-unregistered
signal. Losing the watcher/host restores a hidden window rather than stranding the
app. No tray is required to use the workbench, and no GNOME extension is installed.

This is process-lifetime integration, not login/autostart installation. Tray branding,
question/attention badges, notifications and hardware-panel acceptance remain
pending. In particular, no fake pending-question count or privileged answer action
is exposed. GNOME desktops without StatusNotifier/AppIndicator support remain
window-only; native KDE/GNOME/Wayland panel behavior still needs acceptance.

## Terminal ownership

- `axo-pty::attach` owns the shared v2/v3 wire implementation. v3 supplies the exact grid used to generate its replay, independent of later PTY resizes.
- `axo-client` owns the shared bounded request/event transport also used by the CLI. `LocalCatalog` binds unique pane identities and layouts to their owning Session and refuses relative advertised sockets. `src/workbench.rs` owns only GTK presentation/selection; catalog reads run off-thread with a deadline and do not wake dormant Pi or mutate the catalog.
- `src/task.rs` owns one bounded worker result and cancel-safe GTK delivery. `src/attachment.rs` opens/reads the bounded replay off the GTK thread. Dropping its task removes the delivery callback and closes undelivered attachments; a late worker cannot install a view that was closed.
- `src/ghostty.rs` owns the private, main-thread-only bridge. Widgets retain their engine and immutable prepared attachment through GObject finalization, including before realize.
- `native/bridge.zig` hosts Ghostty's existing GTK Application/Surface classes with supplied prototype defaults. The GTK-only patch initializes at the captured grid and parses the bounded canonical replay during native surface creation, before live I/O threads and actual-viewport resize. No socket I/O runs on the GTK thread. Large-replay initialization latency has not been characterized.
- Ghostty reads output from the attachment socket, **never from the PTY master**. Input, termios queries and host-controlled viewport changes use the master without changing its shared file-status flags. Closing a surface stops its reader and releases duplicates, not the daemon's child process.
- The Rust host owns app/window lifetime: a temporary zero-surface state during catalog load or Session switching is not quit. App-level quit/unrealize also cancels tasks and releases views. Teardown rejects live widgets rather than freeing renderer state beneath them. The Apple XCFramework recipe/patch selection is unchanged; the GTK bridge is a private pinned API, not an upstream stable embedding ABI.

## Controls and parity limits

Human selection/copy/paste uses Ghostty (`Ctrl+Shift+A/C/V`). Output-driven clipboard reads/writes, automatic/OSC links and the inherited Ghostty context menu are restricted until the Axo policy/UI adapters exist. Default Ghostty config files are not loaded or created. The candidate uses a 13-point terminal font, 2-point horizontal/10-point vertical padding and a neutral charcoal palette. Padding follows the Mac defaults, but user config/appearance preferences and copy-on-select policy still need parity work.

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

The `tray_drive.py` driver uses an owned real daemon and a **simulated** native
watcher/host on private D-Bus. It checks protocol/menu export, daemon status,
show/hide/settings/quit, unknown action rejection, watcher-without-host behavior,
recovery when the host disappears but the watcher stays, watcher loss/re-registration
and surviving daemon children. This is not a real desktop-panel visual conformance run.

The `settings_drive.py` driver checks Ctrl+, singleton/draft preservation, no writes
on load, all four persisted settings, server rejection/canonical values, no process
restart, close with settings open, and lost-acknowledgement reload without retry.
It also checks inline label/value geometry, unwrapped caption glyphs and the actual
native sidebar Close button. It uses an owned daemon plus a local protocol fixture;
add GDK3 introspection for its owned-desktop screenshot.

The workbench driver checks 22px row bounds, named caption-free pane groups,
top-edge geometry, actual native Close, semantic AT-SPI sidebar selection A/B/A, two real rendered Pi/terminal PTYs, persisted right/down layout and ratio, keyboard routing, matching kernel grids, multi-pane resize, catalog refresh discovering a new Session without changing selection, child survival and clean teardown. It also rejects termios-query failures (the output socket is not a tty).

Artifacts are retained in the reported private temporary directory. Diagnostic `--snapshot`/`--diagnostics` flags are optional; snapshots contain this window's terminal content and must not be committed from real Sessions.

The Linux server blocked-input teardown regression now passes on this branch:
all 90 server and 54 PTY cases pass in ten complete repeated runs, with no skipped
case. After confirmed child exit, the pane owner retires the Linux master using
`N_NULL`; this never runs on widget detach or a live terminal and never changes
shared file-status flags. The regression retains its isolated 25-second watchdog.
See [the investigation and limits](../README.md#blocked-input-hardening-gate),
including the rejected poll-only approach. This is not a live-write deadline,
native Mac acceptance, or an update to the installed immutable runtime.

Current acceptance uses Ubuntu 26.04/x86-64, GTK 4.22.4, libadwaita 1.9.1 and software OpenGL under Xvfb. It is not a portable release floor, native Wayland/hardware-GPU acceptance, exhaustive terminal/IME/accessibility parity, a persistent installation, or a completed Linux privileged-client trust design.
