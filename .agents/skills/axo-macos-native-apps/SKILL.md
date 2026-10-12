---
name: axo-macos-native-apps
description: Design, implement, or review Axo's native macOS scenes, windows, sidebar/detail UI, commands, settings, AppKit boundaries, and build/validation workflows.
---

# Axo native macOS apps

Resolve paths from the Axo root (`../../..`). Follow [development](../axo-development/SKILL.md) and [packaging](../axo-macos-packaging/SKILL.md). The production app is `apple/AxoMacAxod/`; its window/delegate composition is AppKit, with hosted SwiftUI content and native Ghostty views. `AxodWorkbenchCoordinator` owns observable workbench state and addressed RPC, not processes.

## Window and sidebar

- Preserve the AppKit application delegate, primary `NSWindow`, native split/outline and hosted detail. Do not replace a working source list with SwiftUI solely to change frameworks.
- Window/viewport/layout ownership is presentation state. Workspace/session catalog, runtime ownership and canonical Pi state are separate. Creating/closing/restoring/reflowing a view never admits, clones, stops or retargets a runtime.
- Settings and About are dedicated utility windows with hosted content. Respect content/toolbar safe areas; settings is not a sidebar destination or session detail.
- Expanded sidebar is minimal: bold nonselectable Workspaces heading, folders with nested session rows, one divider, then bold Sessions heading and standalone rows. Folder/hammer glyphs identify records; the hammer does not claim busy-state telemetry. No Axo/plus header, Settings row or extra section separators. The only footer control collapses navigation. Use system materials, semantic colors and standard controls; headings do not add hierarchy levels.
- Multi-selection uses native `NSOutlineView` Shift/Command behavior and identity sets separate from the one displayed session. Adding selected rows/ranges must not unnecessarily replace detail or steal terminal focus. Metadata refresh preserves visible row order, expansion, selected IDs and range anchor.
- Context actions target the clicked row outside selection or the selected set inside it. Rename is single-target only; it captures original target/revision/endpoint. Missing manual-name capability disables unsupported editing. Delete confirms a frozen set of up to 32 session identities, durably reserves the daemon intent, stops exact owned runtimes and tombstones the entire batch only after completion proof. Preserve histories/drafts and original receipts. Unknown/prepared results permit exact read-only reconciliation, never another stop; uncertain runtime ownership is refused. Release only confirmed-deleted presentation surfaces. Move remains unavailable until its daemon lifecycle exists.
- Main-sidebar collapse is a usable 56-point icon rail with accessible destinations, selection cues and a bottom expand control; no inline Create/Settings. Preserve expanded width separately. View → Toggle Sidebar (Control-Command-S) shares the same scoped preference; the main window has no toolbar/sidebar titlebar item. Creation/Settings stay in menus/shortcuts. Diagnostic preference stores must be injected, never mutate normal sidebar preferences. Settings has its own independent rail/width state.

## Creation and session detail

- New Session is direct, one click, no name/progress modal. Command-T uses the active workspace; standalone uses captured HOME. Workspace creation uses the native folder picker and commits its first session atomically.
- Select committed work immediately. Admit the shell before awaiting Pi readiness so shell input remains usable during delayed/unavailable Pi. Keep failures, recovery and unknown outcomes scoped and actionable inline.
- Automatic empty launch requires complete authoritative empty catalogs plus pending/draft/admission fences and the atomic `createIfEmpty` command. Restoration/reconnect does not create work.
- Healthy detail is only the split tree: Pi left, independent shell right, no session/admission/PID/backlog header or pane title strips. Identity belongs in sidebar/window title. No healthy connection status bar, Conversation toggle or Start Pi button; the normal view is terminal-only. Genuine failure/recovery and unknown-command notices remain actionable inline.
- Native manual names and canonical Pi titles are separate. Metadata-only updates with unchanged bindings preserve readers, terminals, chat and field editors.

## Terminal and AppKit boundary

- The renderer launches the captured bundled `axod terminal-attach` presentation child. Pi/shell execution stays in axod. Ghostty's shell-command wrapper supplies `exec -l`; do not prefix a second `exec`.
- Cache by exact machine/host/session/pane/runtime identity with the existing 32-surface bound, no eviction and one interactive viewport owner. Moving an attached retained view within its viewport is not process recreation; another window is a competing viewport.
- Keep Ghostty glyph DPI, framebuffer dimensions and IOSurface layer `contentsScale` synchronized to the owning window. Seed screen scale, retain it during detach/reflow, and update Core Animation under disabled-actions transactions. A content-scale setter alone does not synchronize the compositor.
- Resizing the outer PTY is asynchronous; a surface-size setter is not an input barrier. Preserve the bounded delivery/chunk/credit/control pacing and exact-attachment output coalescing.
- `TerminalView` implements `NSTextInputClient`. Do not use character accessors on modifier-only `flagsChanged` events. Preserve text composition/preedit and captured input authority.
- Accessibility exposes only the actual Ghostty viewport, bounded to 64 KiB, never a transcript/backlog replica. Enabled state follows the input gate; focused state follows the real window responder. Authorized UI automation and VoiceOver use native accessibility, not hidden test execution controls.
- Pane focus is presentation-only. Capture source/destination keys, actual responder, window/viewport owner, layout and logical/physical responder generations. Editor/window transitions invalidate a captured action even after an equal-looking return. Focus only existing attached cached surfaces; never create a surface/process or transfer another viewport.
- Splits use the pinned tree, captured focused anchor, source/session and right/down placement before await. Decoded layout leaves are identities, not launch constructors. Preserve original commands/placement hints and opaque layout data; divider callbacks are generation-fenced. Explicit shell removal requires exact runtime/completion authority. Pi close policy is not inferred.

## Chat, history and drafts

These coordinator/reader/storage capabilities remain exercised by owned native component fixtures; the normal window does not expose a Conversation switch.

- Bind editor callbacks to the rendered machine/workspace/session/pane/chat, with runtime/host dispatch authority captured separately. Revalidate operation/source/endpoint after awaits; do not select a destination globally.
- Preserve bounded single-page history/tool readers, immutable source/read-mode and presentation generations. Do not accumulate pages or infer canonical history from terminal output. A source/head/branch change invalidates captured reads, including equal-looking ABA changes.
- Drafts and local send/steer captures are in-memory only. Limits are 32 conversations, 64 KiB each, 1 MiB aggregate text and 32 pending captures; reject capacity without eviction/truncation or stale submission. Neither app nor daemon persists/restores unsent drafts. Existing retired archives remain untouched and unread.
- Parse the closed operation and complete wire frame before marking dispatch uncertain. Capture exact input authority before preference hint/RPC. Prepared/null/unknown results allow original read-only reconciliation only; the editing buffer is not an outbox or daemon original receipt.
- Acknowledgement clears only the exact unchanged editing revision. Validate original receipts before clearing matching text/hints; a dispatched receipt is not execution proof.
- Quit commits the field editor and discards unsent buffers without a save barrier or daemon stop. Hide/reflow retains the live buffers. Pending commands still fence automatic empty launch; draft storage readiness is no longer a prerequisite.

## Validation lanes

Build and compile fixtures sequentially against shared DerivedData. Use Xcode for the Mac target and actual UI testing; focused AppKit/pure checks are regressions, not substitutes for UI acceptance.

| Lane | Command | Scope |
| --- | --- | --- |
| Xcode UI | `bash scripts/check-mac-ui.sh` | Packaged app; OS-routed Command-T, native range/multi-selection, refresh retention, clicked-row rename, workspace membership, UI-typed Pi response, Cancel/exact-row/cross-workspace batch Delete and unchanged retained canonical history |
| Packaged startup | `bash scripts/check-mac-app-startup.sh` | LaunchServices/delegate/window/bootstrap, exact bundled helper, one empty-launch session, shell/Pi input/output, account login shell, owning-window scale and header-free geometry |
| Unavailable Pi | `AXO_APP_SELF_TEST_CASE=unavailable bash scripts/check-mac-app-startup.sh` | Real app must retain shell usability and refuse success with missing Pi |
| Native workbench | `bash scripts/check-mac-workbench.sh` | Production coordinator/views/PTYs in private owned native fixtures: creation, delayed/failing Pi, restore, chat/drafts and process recovery |
| Focused checks | `scripts/check-mac-{sidebar,terminal,pane-layout,shell-creation,chat-history,tool-output,chat-drafts,owner-lease,voice-keybinding}.sh` | Local state/storage/rendering/control regressions for the affected component |

- `AXO_LOCAL_DAEMON_BINARY` selects the packaged helper for native fixtures. Workbench modes are `AXO_NATIVE_WORKBENCH_MODE=all|chat|drafts`; bounded fresh-root repetitions use `AXO_NATIVE_WORKBENCH_REPETITIONS=1..20`, not same-command retries.
- Rust owns private roots, daemon/process/model setup, public-RPC fixture metadata and filesystem assertions. XCTest uses UI actions/observations only; do not bypass sandbox or Accessibility denials.
- Xcode UI testing refuses while any Axo frontend is open: `XCUIApplication.launch()` can terminate same-bundle applications. Recheck before running and never implicitly close discovered frontends. Test windows are marked temporary and placed on the primary display. Reopen native menus when polling enabled state; an open menu does not revalidate asynchronous admission changes.
- Packaged self-test flags require fresh Rust-prepared private roots and exact capability versions; release apps reject diagnostic flags. The diagnostic app stops only its owned fixture helper on exit. Normal app quit remains non-destructive.
- Native process-crash checks may signal only the fixture's still-unreaped child handle after its durable checkpoint. Preserve exact daemon PTYs and original unknown tickets; do not replay hints/messages.
- Match claims to the lane: folder-picker UI, normal ServiceManagement/helper handoff, argument-free Finder launch, physical keyboard/IME, independent windows, notifications, power loss and move are separate acceptance boundaries. A busy snapshot or rendered text cannot become execution/completion authority.

## Delivery and diagnostics

- Always package `dist/Axo.app` after validated Mac changes; DerivedData is not delivery. Packaging never authorizes live restart or device installation.
- Use bounded allowlisted lifecycle/action facts with the bundle subsystem when logging. Never include terminal/transcript bodies, prompts, private config, paths to sensitive user material, audio, tokens or clipboard data.
- Preserve macOS 26, iOS 18 and Swift language mode 5 unless explicitly changing the project baseline. Do not silently update dependencies or Ghostty pins.
- Report exact source/build/package and running-app status. Keep test evidence and architectural discussion in project documents; skills describe present implementation and repeatable workflow.
