# RFD0058 — native viewport metrics

- Status: Implemented (source-only experimental v2; native Mac/Wayland/fractional-GPU acceptance pending)
- Date: 2026-11-15
- Amends: RFD0054 native Linux desktop

## Problem

The existing `axo.client.viewport.set` models Mac's logical-point geometry,
72-DPI padding and fractional split lengths. Ghostty GTK uses native cell/padding
pixels (96-DPI baseline, fractional content scales) and integer logical allocations.
Guessing those metrics from configured font points or rendered row counts is not
an exact contract for panes which have no attached surface yet.

## Contract

Keep the existing request/serialization behavior for Mac and old clients. Add
`axo.client.viewport.set.v2`, advertised independently, accepting a viewport with
an explicit `rasterization` record: native-surface logical origin, resolved
device-pixel padding and logical-floor split allocation. The shared solver snaps
both device edges (`round(end)-round(start)`) like pinned Ghostty GTK; multiplying
and flooring a width is not equivalent at fractional origins. The Linux host reads
actual cell/padding pixels and GdkSurface framebuffer scale, not Ghostty's font-DPI
scale. Root origin/allocation and actual divider size come from owned GTK widgets. It reports only coherent, nonzero metrics; it never uses socket termios or
changes shared PTY flags. GTK applies the same floor-of-available-space split rule.

The shared Rust viewport solver remains authoritative for unattached panes. Actual
attached surfaces continue resizing their masters after v3 bootstrap; viewport
publication cannot reflow replay before its captured grid. Version 1 refuses a
rasterized request; version 2 requires it. A daemon without version 2 continues
supporting actual attached-surface resize, but does not receive guessed prewarm
geometry. No request is routed as a privileged peer.

Publish via a single shared, coalescing reporter, separate from the read-only
catalog observer. The newest desired value replaces older pending values; writes
are serial and bounded. A failed/lost acknowledgement is uncertain: no automatic
retry in that epoch, until explicit refresh/reconnect. New connection epochs
resend the latest geometry, including unchanged values. Disposal cancels delivery
and sockets, not a write already admitted by the daemon.

## Persistence and compatibility

Store native metadata in a separate viewport key, atomically with a legacy-only
projection in the existing key. Old binaries must still parse that existing key
without unknown fields. A new legacy report clears the native key. This changes
no Session/database schema, identity, pairing, transcript or master ownership.
An old binary's projection is only a compatibility fallback, not a native-pixel
accuracy claim. General downgrade/installer behavior remains a separate gate.

## Acceptance

- Preserve exact existing Mac viewport fixture serialization and grid tests.
- Test resolved padding, integer split partitions, nested layouts and fractional
  scales at grid boundaries; reject invalid metrics before persistence.
- Test v1/v2 capability and payload boundaries, serial/coalesced reporting,
  lost replies without retry, latest-value ordering and reconnect epoch reset.
- Prove unselected/unattached fixture panes get the predicted kernel grids and
  newly created panes start at those grids; shown surfaces keep their real grids.
- Run isolated Ghostty drivers, shared protocol/store/client/server suites and
  retain explicit Mac/real-GNOME/Wayland acceptance limits. No live restart/install.

## Source validation

All ten focused Bazel suites pass, including schema checks and unchanged legacy
fixtures. All 23 client tests pass ten complete runs. All seven isolated GTK
drivers pass; viewport acceptance passes three consecutive repeats. It verifies
native padding/cell/scale/origin persistence, hidden-pane kernel grids, exact grids
after GTK's split allocation settles, new unshown panes, reconnect re-publication,
and a lost viewport acknowledgement fencing size changes until explicit Refresh.
The test distinguishes core-ready from final GTK allocation rather than asserting
against the provisional 50/50 split frame. Native fractional-origin arithmetic is
unit-tested against pinned Ghostty examples; real fractional-scale GPU/Wayland and
Mac acceptance are still separate gates. Without an existing real surface there
are no guessed font metrics: the cold first Session uses the daemon's initial grid
and exact v3 bootstrap until actual metrics become available.
