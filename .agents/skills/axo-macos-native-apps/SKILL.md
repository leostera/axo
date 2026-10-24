---
name: axo-macos-native-apps
description: Design, implement, or review Axo's native macOS scenes, windows, sidebar/detail UI, commands, settings, AppKit boundaries, and build/validation workflows.
---

# Axo native macOS app

Resolve paths from the Axo root (`../../..`). Deliver with [packaging](../axo-macos-packaging/SKILL.md). Architecture rationale and the latest audit are in `docs/axo-app-architecture-audit.md`.

## Ownership

- **Axod owns processes; Pi owns transcripts.** Axod (`crates/axod`, `crates/axo-server`) owns PTYs, Sessions, Workspaces, layouts and Pi lifecycle. The app presents and commands that state over Axod's local JSON-RPC socket; it never spawns, adopts or signals Session processes. Ghostty surfaces run the bundled `axod terminal-attach` helper, which attaches to a daemon-owned PTY.
- `SessionID`/`ShellID` (`apple/AxoRPC/Sources/AxoRPC/Models/Identifiers.swift`) are the only identities. Axod allocates them with SQLite `AUTOINCREMENT`, so they are never reused: after an `await`, revalidate by looking the ID up again.
- Explicit **Restart Pi** may affect only the verified pane; automatic Pi recovery is Axod's idle-only, non-forcing `auto` restart. Closing windows or the app never stops daemon work.

## Source layout (`apple/AxoMac/Sources/AxoMac`)

| Folder | Contents |
| --- | --- |
| `App/` | `AxoApp<Launch>` (scenes, menus), `AxoAppEnvironment` + `AxoLaunchMode` (launch configuration), `AxoWorkbench` (app-lifetime coordination), `ObservationLoop`, `AxoPreferenceKey`, pairing/URL routing, sleep prevention. |
| `Sessions/` | `TerminalSessionsModel` (catalog + selection/focus + commands), `AxodClient` protocol and socket implementation, `TerminalCatalogSync` (event subscription), `TerminalLayout` (pure layout tree), `SessionNavigation`, `TerminalLayoutWriter`, `AutomaticPiRestarter`. |
| `Terminal/` | `GhosttyRuntime` (+`Config`, `Callbacks`, `Actions`, `Clipboard`), clipboard/URL/attention/accessibility policies. `Terminal/Surface/` holds the Ghostty surface view split by concern (keyboard, text input, mouse, menu) and `TerminalKeyEquivalentPolicy`. |
| `Workbench/` | `TerminalWorkbenchView`, sidebar rows and rename editor, workspace sheet, split tree and pane views. |
| `Settings/` | Settings views, `RemoteAccessModel` (fed by `relay.status` events) and `DaemonCommandSettingSection`. Settings talk to Axod only through `AxodSettingsClient`. |

The `AxoMac` library has no `@main`. Two thin entry targets link it: `Sources/AxoMacMain` (shipped app, `ProductionLaunch`) and `Sources/AxoMacTestHost` (self-test and UI-automation launch modes for `AxoUITestApp`, via `@testable import`, so non-optimized builds only). The shipped app must never link `AxoMacTestHost`.

`apple/AxoRPC` holds the wire models and the per-call Unix-socket client; `apple/AxoDaemonManager` holds `DaemonController` (LaunchAgent registration and health).

## State and data flow

- Models are `@Observable` and `@MainActor`. Assign observed properties only when the value changes (`TerminalSessionsModel.assign`): Observation notifies on every write, and the workbench re-renders for each. Mark internal bookkeeping `@ObservationIgnored`.
- `TerminalCatalogSync` keeps the catalog current through one `axo.session.subscribe` subscription with `includeTerminalOutput: false` (catalog events only: no terminal output or `pi.event`). It subscribes before listing, polls batches (`maxEvents`), applies events through `TerminalSessionsModel.apply(_:)` (and `relay.status` to `RemoteAccessModel`), and on lag, reconnect or failure resubscribes and calls `resynchronize()`. Failures publish `catalogConnection = .reconnecting` (shown as a banner) and, after `unreachableThreshold` attempts, ask `DaemonController.checkHealth()` once per outage. Never add periodic polling.
- `AxoWorkbench` is created once in `AxoApp.init` and owns catalog sync, surface reconciliation and keyboard focus via `ObservationLoop`. Views render state and forward intent; do not start lifecycle loops in view `.task`s.
- User commands go through `TerminalSessionsModel` and apply the record Axod returns; relist only when the outcome is ambiguous. Shell creation is not idempotent: an unconfirmed split is reconciled from the catalog, never retried.
- ⌘W uses `requestCloseShell`: `axo.shell.busy` decides whether to confirm (foreground job or Pi turn); if busy state is unknown, ask rather than guess.
- `DaemonController` never restarts axod on a slow health check (it may be recovering Sessions); only a build mismatch or the explicit, confirmed **Restart axod** action restarts the LaunchAgent.
- Selection order and successor rules live in `SessionNavigation`/`RecentSessions`; layout algebra lives in `TerminalLayout`. Keep both pure and unit-tested.
- Preference keys live only in `AxoPreferenceKey` (app) and `DaemonPreferenceKey` (daemon registration); `PreferenceKeyTests` keeps them disjoint.

## Ghostty and AppKit boundary

- Keep Ghostty pinned to revision `81598385d608dda4946093d6d6a234d204a2f225` unless a change is approved; compare behavior against the pinned upstream under `bazel-axo/external/+ghostty_repository+ghostty/source/macos`.
- libghostty callbacks run through `GhosttyRuntime+Callbacks` and hop to the main actor; reject off-main calls. Present UI from callbacks on the next main-loop turn (the renderer mutex may be held).
- One size path: `GhosttySurfaceNSView.syncSurfaceSize()` feeds libghostty from the view's own final bounds and ignores zero/non-finite passes. Never push a SwiftUI proposed size.
- Representables must not publish state synchronously during updates; status callbacks are deferred and typed (`TerminalSurfaceConnection`).
- Keyboard focus has one path: the surface's deferred `requestFocus()` (from the representable or `GhosttyRuntime.requestFocus(for:)`). Do not add retry loops.
- Clipboard consent is a window sheet that completes Ghostty's request asynchronously with owned copies of the reviewed payload; without a window, deny. Do not use `runModal`.
- Surface conformances to AppKit protocols use isolated conformances (`@MainActor NSTextInputClient`), not `@preconcurrency`.

## Validation

| Target | Scope |
| --- | --- |
| `bazel test //apple/AxoMac:AxoMacTests` | Unit tests: models with `FakeAxodClient`, layout, navigation, input policies, surface viewport. |
| `bazel test //apple/AxoMac:TerminalWorkbenchE2ETests` | `TerminalSessionsModel` against an isolated real `axod` with inert Pi fixtures and a private `HOME`. |
| `bazel test //apple/AxoMac:AxoAppSelfTestTests` | The packaged test-host app's `--self-test` attaching to a daemon-owned PTY. |
| `bazel test //apple/AxoRPC:AxoRPCTests //apple/AxoRPC:AxoDaemonInteropTests //apple/AxoDaemonManager:AxoDaemonManagerTests` | Wire models, transport, live-daemon decoding, registration decisions. |
| `bazel test //apple/AxoMac:AxoVisualUITestsBazel` | Real XCUITest UI against an isolated daemon. `AXO_UI_TEST_ONLY=<test>` runs one case. |

- The visual runner refuses to start while any `Axo` frontend is running (XCUIApplication can terminate same-bundle apps). Never close or restart discovered Axo/Axod processes to make room; ask the user.
- Test fixtures must not depend on ambient Pi configuration or the user's database: use `//crates/axo-server:pi_extension_fixture` and `//crates/axod:testdata/pi-fixture.sh`.
- Component tests do not prove real AppKit, IME, VoiceOver or physical-device behavior. Match claims to the lane that ran.
- Keep Axo's own code free of compiler warnings (`bazel build //apple/...`); remaining warnings come from external dependencies.
