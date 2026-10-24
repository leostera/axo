# Ghostty patches

Axo builds Ghostty at the pinned commit in `ghostty_repository.bzl` and applies
these patches before `zig build`. Keep them minimal and self-contained, and
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
- An adopted PTY keeps its size until the surface is really laid out. Its
  program is already running, and the first resize the I/O thread sees is the
  provisional default window size from `Surface.init`; that one is skipped and
  the host asserts the first real grid itself (`GhosttySurfaceNSView`). Later
  resizes reach the PTY as usual.

Without this, the app needs `axod terminal-attach` as a bridge process with a
second PTY between Ghostty and the shell.
