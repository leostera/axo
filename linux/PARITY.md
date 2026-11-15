# Linux parity worklist

Source-only development on `leostera/linux-support`; not a Linux release claim.
Installed executables are immutable older snapshots. No live restart/replacement,
main integration, push or publication without approval. One installed Axo only.

## Completed source checkpoints

- [x] Real pinned Ghostty/GTK rendering, shared v2/v3 attachment ownership/captured grid.
- [x] Persisted split workbench, detach-only selection/quit, native settings and guarded tray.
- [x] Blocked-input pane/daemon teardown with bounded regression workers (`2d26f6a8`).
- [x] Shared live catalog/readiness/reconnect policy (`49fa4499`).
- [x] Native output-EOF retry, stale attachment cancellation, no input replay (`a2682177`).

## Ordered implementation

- [x] Native viewport publication: actual metrics, coalescing, reconnect and unattached panes (RFD0058); source-only, no guessed metrics in an empty cold workbench.
- [ ] Session creation/home/folder UI, explicit uncertain-write recovery, foreground-only dormant Pi wake.
- [ ] Layout editing and ordered persistence; pane focus/navigation and split/close availability.
- [ ] Busy-aware archive/close/reopen, captured IDs and unknown-busy refusal.
- [ ] Grouping/order/seen policy, palette, peer hosts and remote-view/session distinctions.
- [ ] Remaining general/appearance/agent/remote-access preferences; supported controls only.
- [ ] Attention/notifications/branding and single-instance/reopen UX.
- [ ] Reproducible install/update artifacts, supported dependency/kernel matrix, consented upgrade and rollback.

## Acceptance gates (not replaced by fixture tests)

- [ ] Native Mac regression/behavior comparison for changed shared contracts.
- [ ] Real Linux Wayland/GPU/scaling/keyboard/IME/clipboard/accessibility acceptance.
- [ ] Real supported desktop panels, absent-tray behavior and desktop lifecycle.
- [ ] Cold daemon restart, process/runtime failure and recovery matrix.
- [ ] Broader supported kernels/distributions and installation/rollback/data preservation.
- [ ] Approved single installed-runtime update/dogfood, without resetting identity or data.

## Deliberate blockers

Linux privileged approval/secure input stays fail-closed until application
identity and field/origin binding have a reviewed implementation. GNOME 50
capture/focus/input guards stay enabled; missing safe upstream support is a blocker,
not permission to bypass. Authentication secrets, real transcripts/screenshots,
private logs and backups do not belong in commits.

Use private HOME/Xvfb/D-Bus/sockets/fixture daemons for tests. Advance this list with
specific checks and honest limits, never by counting a simulated tray or software
X11 rendering as real desktop acceptance. Progress timers should re-arm only while
work is active, and stop at an approval/platform blocker rather than idle-looping.
