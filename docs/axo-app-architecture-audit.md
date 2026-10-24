# Axo.app architecture and technical-debt audit

Status: audit 2026-10-23; all findings resolved 2026-10-24 (see Resolution). Scope: `apple/AxoMac`, `apple/AxoRPC`, `apple/AxoDaemonManager`, their Bazel targets, packaging and project skills. Rust `axod` internals are out of scope except where the app contract depends on them.

## Current shape

| Area | Files | Notes |
| --- | --- | --- |
| App/scenes/commands | `AxoApp.swift` (425 lines) | App entry, menu bar, two windows, all menu commands, self-test boot, UI-test boot and window placement. |
| Session catalog + layout | `TerminalSessionsModel.swift` (1,424) | RPC orchestration, polling refresh, selection/focus, layout tree algebra, layout persistence, pending split, archive/rename, automatic Pi restart. |
| Workbench UI | `TerminalWorkbenchView.swift` (908) | Sidebar, rename, workspace sheet, refresh loop, split tree, pane views, Pi restart UI. |
| Ghostty runtime | `GhosttyRuntime.swift` (854) | libghostty app/config, C callbacks, surface cache, focus, secure input, clipboard, config defaults, notifications. |
| Ghostty view | `GhosttyTerminalView.swift` (1,467) | Representable, host view/overlays, surface NSView, keyboard, IME, mouse, drag/drop, services, accessibility, key policy. |
| RPC | `UnixSocketRPC.swift` (1,033) | All wire models, requests and a static per-call transport in one file. |

Native unit coverage is reasonable (111 XCTest cases), but production structure concentrates unrelated responsibilities in four files totalling ~4,650 lines.

## Findings, by priority

### P0 — correctness / architecture

1. **Polling replaces the event contract.** `TerminalWorkbenchView` calls `sessions.refresh()` every second, which re-lists all sessions and workspaces. The app negotiates `axo.session.subscribe/events.next/unsubscribe` but never uses them. Consequences: one-second staleness, redundant RPC, full catalog normalization and `@Published` churn every second, and refresh-driven focus/layout mutation racing user actions. Replace with a single subscription-driven catalog store (snapshot + events, resync on gap/reconnect).
2. **View-layer owns lifecycle loops.** Refresh, surface reconciliation and focus retry loops live in `.task` modifiers of a view. Window close/reopen restarts them; multiple windows would duplicate them. Move to a model-owned coordinator started once per app.
3. **Test and diagnostic modes ship in the production app.** `AxoApp` branches on the UI-test bundle ID, `--self-test`, `AXO_UI_TEST_*` env vars, contains `fatalError` paths for missing test env, a title-based window lookup/positioning loop, and `TerminalUITestAutomation` (file-based remote control of terminals) compiled into release. Split into a test-host target/module; release builds must not contain the automation entrypoint.
4. **`TerminalSessionsModel` is a god object.** Separate: catalog store (daemon truth), layout algebra (`TerminalLayout`, pure, already mostly isolated), layout persistence (debounced writer), selection/focus navigation, commands (create/split/close/rename/archive), and automatic Pi restart policy.
5. **Identity is ad hoc.** Selection uses `Int64` session IDs persisted to defaults, while `sessionUuid` is optional and checked only in the split path. Use one typed stable identity (`SessionID`, `ShellID` wrappers) and validate it across every await, not just split.

### P1 — structure / maintainability

6. **`GhosttyTerminalView.swift` mixes five concerns.** Extract: `GhosttySurfaceHostNSView` + overlays; `GhosttySurfaceNSView` core lifecycle/size/focus; keyboard + `NSTextInputClient`; mouse/pressure/drag; services/accessibility; `TerminalKeyEquivalentPolicy`.
7. **`GhosttyRuntime` mixes config, C callbacks and surface registry.** Extract `GhosttyConfigLoader` (defaults/resources/scrollbar/attention config), `GhosttyCallbacks` (C trampolines), and `TerminalSurfaceRegistry` (cache, focus, secure input). Size is pushed through two paths (`updateContentSize` and `updateSurfaceScaleAndSize`); keep one.
8. **`UnixSocketRPC` is one file and a static, connection-per-call API.** Split models by domain (sessions, workspaces, config, remote access) and introduce an injectable `AxodClient` protocol so models can be tested without sockets. Remove dead/duplicate APIs (`listSessions` vs `listSessionSnapshot`, `sendTerminalInput`/`resizeTerminal` if only used by attach helper, both `createSession` overloads) after confirming callers.
9. **Legacy ObservableObject/@Published everywhere,** including no-op publishes (the recent startup hang was one). Migrate app models to `@Observable` (macOS 14+ target needed — current minimum is 13.0; decide) or at minimum guard equal-value assignments and stop publishing from representable updates.
10. **UserDefaults access is scattered** (`TerminalSessionsModel`, `GhosttyRuntime`, `DaemonController`, `@AppStorage` with two different sidebar keys: `terminalSidebarIsCollapsed` in `AxoApp` and `terminalSidebarIsCollapsed.v2` in the workbench — the menu toggle and the view do not share state). Centralize preference keys; fix the split key.
11. **Modal alerts block the main thread** (`runModal` in clipboard consent, untrusted URL, update notice). Use sheet/window-modal presentation tied to the owning window.
12. **Swift 6 concurrency warnings** in `TerminalAttention.swift` (`UNUserNotificationCenter` captured in `@Sendable`); `@unchecked Sendable` event wrapper and `@preconcurrency` conformances in the surface view should be re-audited.

### P2 — build, repo and docs hygiene

13. **Stale project skills.** `.agents/skills/axo-macos-native-apps` and `axo-macos-packaging` describe `apple/AxoMacAxod`, `AxodWorkbenchCoordinator`, `protocol/`, `apple/AxoCore`, `axod/Cargo.toml`, `scripts/check-mac-*.sh` and an NSOutlineView sidebar — none exist. `axo-development` is referenced but missing. Rewrite skills to match the real tree.
14. **Local build litter:** `apple/AxoMac/.build` (245 MB) and `apple/AxoMac/DerivedData` (441 MB) from earlier SwiftPM/Xcode flows; ignored by git but obsolete now that Bazel/rules_xcodeproj own builds. `Package.swift` files are referenced in history but not used by Bazel.
15. **Deployment-target inconsistency:** app `minimum_os_version = "13.0"`, UI tests 14.0, XCTest support dylib 14.0, Rust linker targets 11.0 vs 13.0 (linker warning). Pick one baseline.
16. **`AxoMacTests` lists sources explicitly** while the library uses `glob`; new test files are silently not run unless added by hand. Use a glob.
17. **Placeholders in UI:** "Check for Updates…" opens a not-configured alert. Remove until a release channel exists.
18. **`AxoVisualUITests.swift` (1,388 lines)** duplicates fixture helpers; split per feature with a shared fixture.

## Proposed execution order

Each step is independently buildable, tested (`//apple/AxoMac:AxoMacTests`, RPC tests, isolated visual UI when no frontend is open) and packaged.

1. Hygiene with no behavior change: fix sidebar key bug, test glob, concurrency warnings, remove update placeholder, delete stale local build dirs, rewrite skills.
2. Extract pure/value types and files: `TerminalLayout` + presentation, key policy, RPC models split, preference keys.
3. Introduce `AxodClient` protocol and an app-level `WorkbenchCoordinator` owning lifecycle loops; move refresh/reconcile/focus loops out of views.
4. Replace polling with subscription-driven catalog store; keep a bounded resync path.
5. Split `TerminalSessionsModel` into catalog / layout persistence / navigation / commands / Pi restart policy.
6. Split Ghostty runtime and view files along the boundaries above; single size path.
7. Move UI-test automation and self-test into a test-host target; production app has no test entrypoints.
8. Replace `runModal` with window-attached presentation; decide on `@Observable` migration with the deployment-target decision.

## Resolution

All findings were addressed in independently tested commits (`b54423d`..HEAD):

| Finding | Resolution |
| --- | --- |
| 1 Polling | `TerminalCatalogSync`: one catalog subscription (`includeTerminalOutput: false`), event application in `TerminalSessionsModel.apply`, resubscribe + `resynchronize()` on lag/reconnect. Axod gained lag signalling, idle subscription expiry, `workspace.changed` and `session.focus`. |
| 2 View-owned loops | `AxoWorkbench`, created once in `AxoApp.init`, owns sync, surface reconciliation and focus via `ObservationLoop`. |
| 3 Test modes in release | Test launch modes live in the separate `AxoMacTestHost` entry target (see audit 2, item 15) used only by `AxoUITestApp`; the shipped binary contains no self-test or automation strings. |
| 4 God object | `AxodClient`, `TerminalLayoutWriter`, `AutomaticPiRestarter`, `SessionNavigation`/`RecentSessions` and `TerminalLayout.defaultLayout` extracted; duplicated command paths collapsed; negotiation cached per connection; `SessionCommandError` for app-level failures. |
| 5 Identity | Typed `SessionID`/`ShellID` (wire-compatible integers). Axod's AUTOINCREMENT IDs are never reused, so they are the single identity; `sessionUuid` is no longer compared. |
| 6–7 Ghostty files | View split into `Terminal/Surface/*`; runtime into `+Config`, `+Callbacks`, `+Actions`, `+Clipboard`. One guarded `syncSurfaceSize()` path. |
| 8 RPC | Models split by domain; `UnixSocketTransport` separated; unused `listSessions`, terminal input/resize and relay configure/settings/disable client calls removed. |
| 9 ObservableObject | macOS 14 baseline; all app models are `@Observable` with change-only writes; Combine removed. |
| 10 Defaults | `AxoPreferenceKey`; sidebar key mismatch fixed. |
| 11 `runModal` | Clipboard consent is an asynchronous window sheet (matching pinned Ghostty). `UntrustedURLAlert` is a verbatim Ghostty port that already prefers a sheet and is kept as-is. |
| 12 Concurrency | Notification calls use async APIs; `@preconcurrency` replaced by isolated `@MainActor` conformances; `@unchecked Sendable` invariants documented. No compiler warnings remain in Axo code. |
| 13 Skills | Axo skills rewritten for the current tree; vendored skills' compatibility notes updated. |
| 14–17 Hygiene | Stale build dirs and unused `Package.swift` removed (`apple/AxoRPC/Package.swift` stays: `MODULE.bazel` resolves Swift deps through it); single macOS 14.0 baseline incl. Rust linker; test glob; update placeholder removed. |
| 18 Visual tests | Split per feature with a shared `UITestFixture`; runner filters unchanged. |

Not covered by this audit: real AppKit/IME/VoiceOver acceptance (tracked in `docs/terminal-input-acceptance.md`) and moving Axod's new-Session process creation out of the catalog lock (`docs/axod-recovery-hardening.md`).
