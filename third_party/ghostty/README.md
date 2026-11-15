# Ghostty patches

Axo uses the shared revision in `ghostty_pin.bzl`. The Apple recipe applies 0001;
`linux/AxoDesktop/ghostty_gtk_repository.bzl` applies 0001, 0002 and 0003 before
`zig build`. The separate headless `libghostty-vt` recipe stays unpatched. Keep them minimal and self-contained, and
regenerate them against the pinned commit whenever it changes.

## 0001-external-terminal-io.patch

Adds an external terminal I/O mode to embedded surfaces
(`ghostty_surface_config_s.external_io`). Axod owns every PTY and is its only
reader, so a surface must not spawn a process or read the PTY itself:

- Output is read from `external_output_fd` (Axod's attach socket: replay, then
  live bytes). End of file is reported as a child exit.
- Input, resizes and termios/foreground queries go to `external_pty_fd`, the
  PTY master Axod passed over `SCM_RIGHTS`. Its file status flags are never
  changed, because the open file description is shared with Axod.
- The surface duplicates both descriptors; the caller keeps the originals.
- `initial_width`/`initial_height` (pixels) replace the 800x600 placeholder a
  surface starts with. The output stream is parsed as soon as the surface
  exists, so a replay must meet the grid it was written for; parsed narrower,
  it soft-wraps and stays mangled after the reflow.
- An adopted PTY keeps its size until the surface is really laid out. Its
  program is already running, and the first resize the I/O thread sees is the
  provisional default window size from `Surface.init`; that one is skipped and
  the host asserts every applied grid itself (`GhosttySurfaceNSView`), because
  when the first layout pass is transient the skipped resize is the real grid.
  Later resizes reach the PTY as usual.

Without this, the app needs `axod terminal-attach` as a bridge process with a
second PTY between Ghostty and the shell.

It also exposes `window-padding-x` and `window-padding-y` through
`ghostty_config_get` (`ghostty_config_padding_s`, points before DPI scaling).
Axod sizes panes that no surface shows yet from the client's viewport, so Axo
must report the padding the final config (including the user's Ghostty config)
uses, not the default it loaded first.

## 0002-gtk-widget-bridge.patch

Enables Ghostty's existing GTK runtime and renderer dependencies when building a
library. Adds caller-supplied GTK application configuration so the host need not
load/create another application's default config. The private Zig bridge returns
real Ghostty GTK widgets; this is not VTE or a replacement terminal renderer.

## 0003-gtk-external-terminal.patch

Wires external I/O through the GTK Surface adapter, borrowing descriptors and a
bounded prepared replay whose Rust owner lives through GObject finalization. The
core initializes at the server-captured VT grid and parses the replay before its
live reader starts. GTK then applies its actual viewport; the host owns kernel
PTY resize assertions so queued provisional resizes cannot race them. An external
surface's close is detach, never permission to stop the daemon-owned process.
Termios polling uses the write-side PTY master, not the read-side attach socket;
normal spawned terminals still query their same master. The host config disables
Ghostty's last-surface quit timer so Session replacement can pass through zero
surfaces without quitting the Rust-owned window.

These hooks are GTK-build-only and do not alter the Apple embedding's wire or
renderer behavior. Snapshot-grid metadata belongs to shared attach protocol v3,
not a Linux-only VT escape or a second terminal backend. See RFD0054/RFD0055 and
`linux/AxoDesktop/tests/attach_drive.py` for the contract and real-daemon fixture.
