# Axo.app audit, second pass

Status: audit, 2026-10-24. Follows `docs/axo-app-architecture-audit.md` (all of its findings resolved). Scope: `apple/*` plus the Axod event/subscription contract the app now depends on.

## P0 — correctness

1. **The catalog subscription receives every Pi stream event.** Axod's `publish_event` excludes only `terminal.output` from `includeTerminalOutput: false` subscribers. `pi.event` (one per Pi `message_update`, `tool_execution_update`, …) still reaches the app's catalog subscription. Each costs one socket connection plus one JSON-RPC round trip (`events.next` returns a single event), is decoded only to be ignored as `.unknown`, and a long turn can overflow the 128-event queue and force full `subscription.lagged` resyncs. Introduced by the first pass's switch from polling to events. Fix: make catalog subscriptions receive catalog events only (`session.snapshot`, `session.removed`, `workspace.changed`, `session.focus`, `shell.activity`).
2. **`next_event` holds the global `subscriptions` mutex while long-polling.** `recv_timeout` (up to 20 s) runs under the lock, so a waiting subscriber blocks every other subscriber's `events.next`, `subscribe` and `unsubscribe`. The relay polls its stream with a zero timeout in the same loop that reads remote requests, so while the Mac app's 15 s catalog long-poll is waiting, remote terminal output **and** remote input stall for up to 15 s. Latent before, but exposed by the first pass (the app was not a subscriber then). Fix: per-subscription receivers behind their own lock (or take the receiver out of the map for the wait), never a shared lock across a blocking wait; add a concurrency test with two subscribers.
3. **Connection loss is invisible.** `DaemonController.status` is computed once at startup and never rechecked; `TerminalCatalogSync` retries failures with backoff but never reports them. If axod stops, the app keeps showing a stale catalog as "running" with no error. Fix: catalog sync publishes a connection state (connected / reconnecting with last error) that the workbench shows, and a failed sync re-checks daemon health.
4. **A slow daemon is treated as a wrong daemon.** `checkBuildAndRestartIfNeeded` unregisters and re-registers the LaunchAgent (restarting axod) when the health check exceeds 30 s, which can happen while axod recovers many Sessions. That terminates shells it was about to serve. Fix: a startup timeout reports `.failed`/"still starting" and keeps waiting or offers an explicit restart; only a confirmed build mismatch may restart, per the existing restart policy.

## P1 — structure

5. **Settings bypass the client layer.** `SettingsView` (agent and shell command sections) and `RemoteAccessSettingsView` call `UnixSocketRPC` with `DaemonController.socketPath()` directly, cannot be tested without a socket, and the two command sections are near-identical copies (~110 lines each). Fix: a small `AxodSettingsClient` (config get/set, relay status/connect/link) plus one reusable `DaemonCommandSettingSection`.
6. **Remote-access status polls every second** while Settings is open (`monitorConnection`). Fix: an Axod `relay.status` event on the catalog stream (or at least an event-driven refresh after connect/link), keeping one bounded slow poll only as a fallback.
7. **Pane connection status is a free-form string.** `GhosttySurfaceNSView.status` carries messages like `"Connected to shell 285"`, and `TerminalPaneView` decides whether to show an error with `status.hasPrefix("Connected to ")`. Fix: a `TerminalSurfaceConnection` enum (`starting`, `connected`, `failed(String)`).
8. **Keyboard focus has two owners with timer retries.** `AxoWorkbench.focus` polls `focusSurface` 40×25 ms while the representable already calls `GhosttySurfaceNSView.requestFocus()`, which defers until the view joins a window (`viewDidMoveToWindow`). Fix: one owner. The workbench sets the runtime's focused shell and asks the surface to request focus, with no polling loop.
9. **`pasteText` sleep-polls for a surface** (40×25 ms), although both callers (pointer and context menu) run on an existing surface. Fix: paste synchronously, failing if there is no surface.
10. **Commands double-fetch.** `renameSession`, `renameWorkspace`, `archiveWorkspace`, `archiveSession` and `restartPiSession` call `refresh()` (a full listing) after Axod has already published the resulting snapshot or removal events. Fix: rely on events, and reconcile only on an ambiguous outcome (as split already does).
11. **`events.next` delivers one event per connection.** Every event costs a new Unix-socket connection and JSON-RPC session. After fix 1 this is low-volume, but bursts (archiving a Workspace, startup recovery) are still N round trips. Fix: let `events.next` return a bounded batch (additive `maxEvents`, schema-checked).

## P2 — polish and hygiene

12. `ContentUnavailableViewPlaceholder` re-implements SwiftUI's `ContentUnavailableView` (available on macOS 14).
13. **Menu conventions:**
    - Toggle Sidebar is ⌘S; macOS convention is ⌃⌘S.
    - "Cut" in a terminal only copies.
    - ⌘W closes a shell, killing its process, with no confirmation even while a command is running.
    These need UX decisions, not just code changes.
14. `TerminalWorkbenchView.swift` (886 lines) still holds the sidebar, rename editor, workspace sheet, layout and pane views; split into `Workbench/Sidebar/*`, `WorkspaceCreationSheet`, `TerminalPaneView`. `SettingsView.swift` (519) similarly.
15. **Double compile for tests.** `AxoMacTestHost` recompiles every app source to add `TestHost/`. Fix: move `@main` into two thin entry targets over one shared library, so the test host links the same compiled app code.
16. `DaemonController` keeps its own raw `UserDefaults` keys and uses `Task.sleep(nanoseconds:)`; move the keys next to `AxoPreferenceKey` (shared module) and use `Duration`.
17. **Rust strict Clippy:** the documented pre-existing categories remain (`too_many_arguments` ×4, `manual_is_multiple_of`, `chunks_exact`).

## Proposed order

1. Fixes 1–2 (Axod), with two-subscriber and relay-latency tests. These are regressions affecting remote use today.
2. Fixes 3–4: connection state and safe startup handling.
3. Fixes 7–10: focus, paste and status typing, event-only command reconciliation.
4. Fixes 5–6 and 11: settings client and events, batched `events.next`.
5. P2 items, with the UX decisions in item 13 confirmed by the user first.
