# AxoDesktop — native Linux workbench (in progress)

A Rust/GTK4 window embedding the **real pinned Ghostty GTK terminal surface**, its VT engine, renderer, fonts and native input machinery. Not GNOME VTE, a browser, or a home-grown text renderer.

The first local workbench has a compact Session sidebar, selected Session, real Pi/terminal panes from the daemon's persisted right/down layout, live catalog updates, reconnect, replay/input and resize. Switching Sessions or quitting detaches; children keep running. Closing hides the window only when a tray host is confirmed; otherwise it quits. It uses the shared Rust client, not a CLI subprocess or separate backend. This is **not yet Mac feature/visual parity**: exited-Pi recovery, layout writes, archive/close, grouping and palette remain pending. Native settings now expose daemon-owned shell/agent commands and idle Pi limits; appearance, power, grouping and remote-access settings remain pending. The presentation now follows screenshots of the running Mac app: neutral grouped settings with inline values, a fixed 220px sidebar with 22px Session rows, native drag/window controls and caption-free, full-height panes. This is not a complete Mac visual/behavioral conformance claim.

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

**Workbench ownership:** `--socket` asks that daemon to open its bundled `AxoDesktop` through `axo.client.desktop.open`. The initial launcher exits; only the exact live child retained by axod initializes the workbench and gains local pane control. Install the matching binaries plus `lib/` and `share/ghostty/` together beside one another. Development workbenches need the same isolated runtime layout; a loose Bazel binary is not automatically trusted. No caller-chosen executable, PID, environment token or same-UID allowlist grants access. This does not grant human approval/sign-in authority or authorize the desktop's descendants. See [RFD0086](../../docs/rfds/RFD0086-linux-managed-desktop-pane-access.md).

**Attachment requires snapshot-capable protocol v3**, implemented by the candidate daemon ([RFD0055](../../docs/rfds/RFD0055-terminal-snapshot-grid.md)). An older daemon's refusal is shown; no guessed-grid downgrade or local-shell fallback occurs. The candidate server keeps v2 unchanged for shipped Mac/peer clients. Do not install/restart a paired daemon just to try this UI: use an isolated daemon first; deployment is a separate approved operation.

The `run` target resolves process-local resources/libraries from Bazel runfiles. This is not an installer or service. The prototype uses `dev.leostera.AxoDesktop.Prototype` and does not join a running Ghostty app. Rootless development prefixes can be supplied through `PKG_CONFIG_PATH`, `PATH`, `PYTHONPATH` and `XDG_DATA_DIRS` in repository-rule/build-script environments; project files contain no machine-specific prefix.

## Presentation

`src/style.rs` styles only Axo-owned windows, not the desktop theme or Ghostty's
renderer. The workbench keeps GTK CSD move/resize behavior and the platform's
window-control order inside the sidebar; the terminal has no full-width titlebar.
The unneeded wordmark and visible pane captions are removed; Pi/terminal groups
retain accessible names. Session rows have the daemon's last-read status, emoji or
native fallback glyph; sleeping Pis stay gray rather than appearing ready. A single shared Rust catalog subscription now drives freshness; manual Refresh
remains available without recreating healthy panes. There is no fabricated unseen
or grouping state. Footer actions retain accessible names/tooltips and keyboard
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
- `axo-client` owns the shared bounded request/event transport also used by the CLI. `LocalCatalog` binds unique pane identities and layouts to their owning Session and refuses relative advertised sockets. `src/workbench.rs` owns only GTK presentation/selection; `CatalogWatcher` owns one read-only subscription and bounded catalog/health reads, without waking dormant Pi or mutating the catalog. `src/catalog_task.rs` bridges one latest-state mailbox to GTK and cancels the worker on teardown.
- `src/task.rs` owns one bounded worker result and cancel-safe GTK delivery. `src/attachment.rs` opens/reads the bounded replay off the GTK thread. Dropping its task removes the delivery callback and closes undelivered attachments; a late worker cannot install a view that was closed.
- `src/ghostty.rs` owns the private, main-thread-only bridge. Widgets retain their engine and immutable prepared attachment through GObject finalization, including before realize.
- `native/bridge.zig` hosts Ghostty's existing GTK Application/Surface classes with supplied prototype defaults. The GTK-only patch initializes at the captured grid and parses the bounded canonical replay during native surface creation, before live I/O threads and actual-viewport resize. No socket I/O runs on the GTK thread. Large-replay initialization latency has not been characterized.
- Ghostty reads output from the attachment socket, **never from the PTY master**. Input, termios queries and host-controlled viewport changes use the master without changing its shared file-status flags. Closing a surface stops its reader and releases duplicates, not the daemon's child process.
- The Rust host owns app/window lifetime: a temporary zero-surface state during catalog load or Session switching is not quit. App-level quit/unrealize also cancels tasks and releases views. Teardown rejects live widgets rather than freeing renderer state beneath them. The Apple XCFramework recipe/patch selection is unchanged; the GTK bridge is a private pinned API, not an upstream stable embedding ABI.

## Live catalog and reconnect

The shared watcher subscribes before reading the authoritative catalog. Events
invalidate reads rather than applying older subscription snapshots; bursts coalesce,
and idle catalogs do not poll the daemon. EOF, lag, malformed frames and failed
reads discard both connections and retry with bounded backoff. Offline/starting
views are detached and input-disabled; selection is preserved for recovery. A new
subscription epoch forces fresh v3 attachments even if every pane ID/PID/path
matches and GTK missed the intermediate offline notification. Metadata-only updates
and healthy manual refresh keep the selected widgets intact.

Independent attachment EOF comes from Ghostty's existing native `child-exited`
notification after output is drained. Widget replacement is deferred beyond the
native callback, then weak view identity is checked. A single selected-view timer
backs off read-only attach retries from 500 ms to 5 s. Transient handshake failures
retry; unsupported v3/invalid replay and renderer failures remain explicit errors
without downgrade or shell fallback. Manual Refresh can retry a failed view.
Selection changes/quit cancel retries and stale delivery; the reconnect controller
never queues or replays input or settings writes. Tray daemon status uses this same catalog
owner instead of another health poller. A failed worker is shown as stopped with
explicit Refresh recovery, never a fabricated reconnect loop.

The read-only observer never creates/wakes Sessions or writes layouts; explicit
creation and foreground dormant wake have separate mutation owners. Cross-client
focus intents and layout writes remain separate product slices.

## Explicit Session creation

The sidebar's New Session control offers current-context, Home and native folder
selection. Ctrl+N creates beside the current local Session (Home without a current
selection); Ctrl+Shift+N opens GTK's FileDialog. Only existing typed shared RPCs are
used, never a CLI subprocess or guessed frontend Session record.

One creation may be pending. Its 40-second total deadline accounts for the daemon's
30-second Pi-start wait. An uncertain/invalid reply or lost worker disables further
creation across refresh, resize and reconnect until the person reviews the catalog
and explicitly acknowledges the notice. That acknowledgement does not resend;
a subsequent action is a new intent. Preflight failures are explicitly not sent.
Success selects only an authoritative catalog record and cannot override a newer
selection. Closing cancels delivery, not an already admitted action. Exited-Pi recovery,
recent-folder suggestions and clone/import controls are not implemented by this slice.

## Foreground dormant-Pi wake

Like Mac's `wakeSelectedPi`, the native selection owner asks once for a selected
Dormant Pi when this main window is visible, active and online. Background catalog
projection or Settings focus cannot start it. It uses only advertised automatic
unavailable-only restart; unavailable/exited panes are not implicitly force-recovered.
One bounded worker runs at a time. Uncertain/unsupported attempts are not replayed
by refresh, selection changes or reconnect. Authoritative available/gone state
reconciles them; the Wake Pi button is a distinct explicit unavailable-only intent.
An admitted request can finish after leaving the view, but its reply cannot select
its old target. A newer current selection can wake after that worker finishes.

For an exact unchanged layout and member IDs, availability/process changes replace
only that pane's contents. Healthy siblings retain their actual Ghostty widget,
attachment and focus; they are never reparented. Slot-local generations fence late
attach/EOF/frame/focus callbacks. Authoritative replacement cancels obsolete retry
state. Initial pane focus deferred behind Settings is fulfilled only on real main
window activation, without rebuilding the terminal. Transport epochs and changed
layouts/membership still use fresh-v3 Scene replacement; ratio/topology editing and
ordered persistence remain separate. Daemon children, PTYs and replay stay authoritative.

## Native viewport publication

The separate shared `ViewportReporter` coalesces actual rendered metrics and
serially sends the newest viewport through advertised `axo.client.viewport.set.v2`.
The GTK bridge exports actual cell/padding pixels and framebuffer scale, keeping
font-DPI scaling separate. Root origin and snapped device spans match Ghostty GTK;
integer split allocation is shared with the daemon. Unattached and new panes get
projected grids while attached surfaces retain actual master resize after v3
bootstrap. Origin-only/activation changes are observed, without socket I/O on GTK.

Native data is persisted atomically beside a legacy-only projection, leaving the
old reader's key/schema unchanged. v1 rejects native fields; v2 requires them. Missing
v2 support is shown explicitly, without guessing a v1 geometry. Uncertain replies
block further automatic viewport writes in that epoch, even on resize, until
explicit Refresh or reconnect. No input/settings action is retried. Metrics require
an actual coherent surface; an empty cold workbench does not launch a metrics shell
or invent font dimensions. See [RFD0058](../../docs/rfds/RFD0058-native-viewport-metrics.md).

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

The managed-workbench regression uses the production admission rule, no identity proxy:

```sh
AXO_DESKTOP_SMOKE_DRIVER="$PWD/linux/AxoDesktop/tests/managed_workbench_drive.py" \
linux/AxoDesktop/tests/smoke.sh /path/to/isolated-runtime/AxoDesktop
```

That runtime must contain matching `axod`, `AxoDesktop`, `lib/` and `share/ghostty/`.
The driver owns a private HOME/display/bus/store and checks launcher handoff,
existing/new Session panes, singleton opens and native Close/reopen. It never
reads personal terminal contents or uses a permissive attachment hook.

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
top-edge geometry, actual native Close, semantic AT-SPI sidebar selection A/B/A, two real rendered Pi/terminal PTYs, persisted right/down layout and ratio, keyboard routing, matching kernel grids, multi-pane resize, live catalog create/rename/remove without recreating selected panes, healthy explicit refresh, child survival and clean teardown. It also rejects termios-query failures (the output socket is not a tty).

`reconnect_drive.py` adds an owned RPC/attach proxy around that same real fixture
daemon. It cuts catalog transport and attachment output independently, holds a late
handshake across a selection change, checks new epochs/fresh replay, exactly two
native pane groups, unchanged child PIDs/input counts, no replay of keys typed
while offline, and released connections on quit. The proxy forwards v3 descriptor
markers with CLOEXEC and never changes shared master flags. Run it with the same
isolated launcher as the other drivers; no live service is restarted. The current candidate passes all nine GTK drivers,
with additional reconnect/viewport/creation/wake repeats, and all ten focused Bazel suites. The 30
shared client tests pass ten complete runs. Some unchanged server/PTY/IPC/protocol
checks are cached in this slice; native Mac and real Wayland/GPU acceptance were
not rerun. Cold daemon-restart acceptance remains separate from these transport-cut
tests. `viewport_drive.py` also checks actual native metrics against hidden/new
kernel grids, exact settled visible grids, old-reader persistence, reconnect resend
and admitted-write/lost-acknowledgement recovery with no resize-triggered retry.

`creation_drive.py` verifies real daemon creation in current/Home/chosen folders,
native chooser cancellation, one pending request, late completion preserving newer
selection, admitted-write/lost-ack fencing across reconnect/refresh/resize, explicit
review without replay, a new subsequent intent, original child survival and clean
close while creation is admitted. The private Xvfb bus routes only FileChooser to
GTK because GNOME's headless portal deliberately omits that interface; no real
portal preferences or capture/input/approval guards are modified. Named native
buttons are exercised through AT-SPI activation and folder selection through the
actual portal dialog's keyboard interface; this is not full real-panel/mouse/Wayland
accessibility acceptance.

`wake_drive.py` uses a clean restart of its owned daemon and Bazel's wire-level
`//crates/axod:fake_pi` fixture (build it first). It verifies old Pis restored dormant,
background selection behind Settings, foreground-only wake, preserved terminal
focus/input/PIDs, held/lost acknowledgements, no wake replay across epoch changes,
missing auto capability without force fallback, explicit new intent and detach-only
quit. Expanded checks retain scene/pane generations and sibling attachment/PID through
owned Pi exit/recovery, hold a superseded handshake across a second replacement,
and prove only current IO installs with terminal keyboard focus intact. This fixture's cold-restore scenario is not the full installation/runtime
failure matrix, real Pi model behavior or real paired-data restart acceptance.
`AXO_DESKTOP_TRACE=1` optionally traces only the fixture frontend's ioctl/close calls.
The live-phase no-termios-error assertion remains strict. An intentional fixture Pi
exit can race one last Ghostty mode poll with confirmed-exit `N_NULL` retirement;
tracing verifies TCGETS2 success then EINVAL/EIO on that master, not a socket or
closed descriptor. Only the known post-exit mode failure is permitted in that phase.

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
