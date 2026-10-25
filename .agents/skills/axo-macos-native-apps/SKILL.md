---
name: axo-macos-native-apps
description: Design, implement, or review Axo's native macOS scenes, windows, sidebar/detail UI, commands, settings, AppKit boundaries, and build/validation workflows.
---

# Axo native macOS app

Resolve paths from the Axo root (`../../..`). Deliver with [packaging](../axo-macos-packaging/SKILL.md). Architecture rationale and the latest audit are in `docs/axo-app-architecture-audit.md`.

## Ownership

- **Axod owns processes; Pi owns transcripts.** Axod (`crates/axod`, `crates/axo-server`) owns PTYs, Sessions, Workspaces, layouts and Pi lifecycle. The app presents and commands that state over Axod's local JSON-RPC socket; it never spawns, adopts or signals Session processes. Each Ghostty surface attaches in-process to a daemon-owned PTY (`TerminalAttachment`, attach protocol v2): Axod is the PTY's only reader and streams replay plus live output; the surface gets the PTY descriptor for input, resizing and termios only (Ghostty external-I/O patch). `axod terminal-attach` is a CLI for tests and debugging, not part of the app.
- `SessionID`/`ShellID` (`apple/AxoProtocol/Sources/AxoProtocol/Identifiers.swift`) are the only identities. Axod allocates them with SQLite `AUTOINCREMENT`, so they are never reused: after an `await`, revalidate by looking the ID up again.
- Explicit **Restart Pi** may affect only the verified pane; automatic Pi recovery is Axod's idle-only, non-forcing `auto` restart. Closing windows or the app never stops daemon work.

## Source layout (`apple/AxoMac/Sources/AxoMac`)

| Folder | Contents |
| --- | --- |
| `App/` | `AxoApp<Launch>` (scenes, menus), `AxoAppEnvironment` + `AxoLaunchMode` (launch configuration), `AxoWorkbench` (app-lifetime coordination), `ObservationLoop`, `AxoPreferenceKey`, pairing/URL routing, sleep prevention. |
| `Sessions/` | `TerminalSessionsModel` (commands, and the observed projections of the two values below), `SessionCatalog` (open Sessions, sorted and unique by ID), `WorkbenchSelection` (selected Session, focus, every layout, recent Sessions), `AxodClient` protocol and socket implementation, `TerminalCatalogSync` (event subscription), `TerminalLayout` (pure layout tree), `SessionNavigation`/`SidebarSections`, `TerminalLayoutWriter`, `ViewportReporter`, `AutomaticPiRestarter`. |
| `Terminal/` | `GhosttyRuntime` (+`Config`, `Callbacks`, `Actions`, `Clipboard`: the libghostty app, preferences, focus, attention, secure input, command routing), `TerminalSurfaceRegistry` (every surface: create at its pane's size, attach, reattach via `ReattachThrottle`, offscreen sizing, free), clipboard/URL/attention/accessibility policies. `Terminal/Surface/` holds the Ghostty surface view split by concern (keyboard, text input, mouse, menu) and `TerminalKeyEquivalentPolicy`. |
| `Workbench/` | `TerminalWorkbenchView`, `WorkbenchSidebar` and its rows and rename editor, workspace sheet, split tree, pane views and `TerminalPaneGeometry`. |
| `Palette/` | The ⇧⌘P command palette (View menu): `CommandPaletteCatalog` (entries from a `CommandPaletteContext` snapshot), `CommandPaletteModel` (query, results, selection), `CommandPalettePerformer` (revalidates every target when chosen), `CommandPaletteView` (overlay; interaction adapted from Ghostty's palette). |
| `Settings/` | Settings views, `RemoteAccessModel` (fed by `relay.status` events) and `DaemonCommandSettingSection`. Settings talk to Axod only through `AxodSettingsClient`. |

The `AxoMac` library has no `@main`. Two thin entry targets link it: `Sources/AxoMacMain` (shipped app, `ProductionLaunch`) and `Sources/AxoMacTestHost` (self-test and UI-automation launch modes for `AxoUITestApp`, via `@testable import`, so non-optimized builds only). The shipped app must never link `AxoMacTestHost`.

`apple/AxoProtocol` holds the wire models (typed: `PaneRole`, `PaneAvailability`), events, layouts, `AxodMethodName` (the only place a method name is spelled) and the protocol version, with no I/O; `apple/AxoRPC` holds the per-call Unix-socket client, whose methods are one table (`AxodMethods` pairs each name with its params and result types), and `TerminalAttachment`; `apple/AxoDaemonManager` holds `DaemonController` (LaunchAgent registration and health); `apple/AxoSearch` holds client-side ranking (`SearchIndex` over `SearchDocument`s, on FuzzyMatch's Smith-Waterman mode), shared with iOS.

Remote Swift packages are listed once in `apple/Package.swift` and pinned in `apple/Package.resolved` (the only manifest `swift_deps` reads); add a dependency there and in the using package's own `Package.swift`, then `swift package resolve` in `apple/`.

## State and data flow

- Models are `@Observable` and `@MainActor`. Assign observed properties only when the value changes (`TerminalSessionsModel.assign`): Observation notifies on every write, and the workbench re-renders for each. Mark internal bookkeeping `@ObservationIgnored`.
- `TerminalCatalogSync` keeps the catalog current through one `axo.session.subscribe` subscription with `includeTerminalOutput: false` (catalog events only: no terminal output or `pi.event`). It subscribes before listing, polls batches (`maxEvents`), applies events through `TerminalSessionsModel.apply(_:)` (and `relay.status` to `RemoteAccessModel`), and on lag, reconnect or failure resubscribes and calls `resynchronize()`. Failures publish `catalogConnection = .reconnecting` (shown as a banner) and, after `unreachableThreshold` attempts, ask `DaemonController.checkHealth()` once per outage. Never add periodic polling.
- `AxoWorkbench` is created once in `AxoApp.init` and owns catalog sync, surface reconciliation and keyboard focus via `ObservationLoop`. Views render state and forward intent; do not start lifecycle loops in view `.task`s.
- User commands go through `TerminalSessionsModel` and apply the record Axod returns; relist only when the outcome is ambiguous. Shell creation is not idempotent: an unconfirmed split is reconciled from the catalog, never retried.
- ⌘W uses `requestCloseShell`: `axo.shell.busy` decides whether to confirm (foreground job or Pi turn); if busy state is unknown, ask rather than guess.
- `DaemonController` never restarts axod on a slow health check (it may be recovering Sessions); only a build mismatch or the explicit, confirmed **Restart axod** action restarts the LaunchAgent.
- Selection order and successor rules live in `SessionNavigation`/`RecentSessions`; layout algebra lives in `TerminalLayout`; what is shown and focused lives in `WorkbenchSelection`; the catalog's ordering in `SessionCatalog`. Keep all four pure and unit-tested; the model only projects them (with `assign`) and performs I/O.
- The command palette searches a snapshot taken when it opens. Its actions carry the IDs the user saw (destructive ones name the exact Session or shell), and `CommandPalettePerformer` skips any whose target closed or changed. Add a command to `CommandPaletteCommand` and the menu together, gated by the same `TerminalCommandAvailability`.
- Preference keys live only in `AxoPreferenceKey` (app) and `DaemonPreferenceKey` (daemon registration); `PreferenceKeyTests` keeps them disjoint.

## Ghostty and AppKit boundary

- Keep Ghostty pinned to revision `81598385d608dda4946093d6d6a234d204a2f225` unless a change is approved; compare behavior against the pinned upstream under `bazel-axo/external/+ghostty_repository+ghostty/source/macos`.
- libghostty callbacks run through `GhosttyRuntime+Callbacks` and hop to the main actor; reject off-main calls. Present UI from callbacks on the next main-loop turn (the renderer mutex may be held).
- One size path: `GhosttySurfaceNSView.syncSurfaceSize()` feeds libghostty from the view's own final bounds and ignores zero/non-finite passes. Never push a SwiftUI proposed size.
- Representables must not publish state synchronously during updates; status callbacks are deferred and typed (`TerminalSurfaceConnection`).
- Keyboard focus has one path: the surface's deferred `requestFocus()` (from the representable or `TerminalSurfaceRegistry.requestFocus(for:)`). Do not add retry loops. Overlays that take the keyboard (the command palette) focus their field on the next main-loop turn and, when dismissed, return focus with `requestFocus(for: focusedShellID)`.
- Clipboard consent is a window sheet that completes Ghostty's request asynchronously with owned copies of the reviewed payload; without a window, deny. Do not use `runModal`.
- Surface conformances to AppKit protocols use isolated conformances (`@MainActor NSTextInputClient`), not `@preconcurrency`.

## Validation

| Target | Scope |
| --- | --- |
| `bazel test //apple/AxoMac:AxoMacTests` | Unit tests: models with `FakeAxodClient`, layout, navigation, input policies, surface viewport. |
| `bazel test //apple/AxoMac:TerminalWorkbenchE2ETests` | `TerminalSessionsModel` against an isolated real `axod` with inert Pi fixtures and a private `HOME`. |
| `bazel test //apple/AxoMac:AxoAppSelfTestTests` | The packaged test-host app's `--self-test` attaching to a daemon-owned PTY. |
| `bazel test //apple/AxoProtocol:AxoProtocolTests //apple/AxoRPC:AxoRPCTests //apple/AxoRPC:AxoDaemonInteropTests //apple/AxoDaemonManager:AxoDaemonManagerTests` | Wire models and event decoding, transport, live-daemon decoding, registration decisions. |
| `bazel test //apple/AxoMac:TerminalWorkbenchE2ETests --test_env=AXO_RUN_BENCHMARKS=1 --test_filter=testBenchmarkSwitchingSessions --test_sharding_strategy=disabled --test_output=all` | The Session-switch benchmark (`BENCH session_switch_ms`); skipped otherwise. The E2E target runs in 3 shards, so any `--test_filter` run needs `--test_sharding_strategy=disabled`. |
| `bazel test //apple/AxoMac:AxoVisualUITestsBazel` | Real XCUITest UI against an isolated daemon. `AXO_UI_TEST_ONLY=<test>` runs one case. |

- The visual runner refuses to start while any `Axo` frontend is running (XCUIApplication can terminate same-bundle apps). Never close or restart discovered Axo/Axod processes to make room; ask the user.
- Test fixtures must not depend on ambient Pi configuration, the user's login shell or the user's database: use `//crates/axo-server:pi_extension_fixture` and `//crates/axod:testdata/pi-fixture.sh`, and a private `HOME`.
- A daemon fixture is ready when its socket accepts a `connect()`, not when the socket file exists (the file appears at `bind()`, before `listen()`). Give every fixture its own directory; never derive one from a timestamp alone.
- Component tests do not prove real AppKit, IME, VoiceOver or physical-device behavior. Match claims to the lane that ran.
- Keep Axo's own code free of compiler warnings (`bazel build //apple/...`); remaining warnings come from external dependencies.
