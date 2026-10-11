---
name: axo-macos-native-apps
description: Design, implement, or review Axo's native macOS scenes, windows, sidebar/detail UI, commands, settings, AppKit boundaries, and build/validation workflows.
---

# Axo native macOS apps

Apply the desktop-native recommendations in these first-party guides to Axo's architecture and operational constraints:

- [Build for macOS](https://learn.chatgpt.com/use-cases/native-macos-apps.md)
- [Build a Mac app shell: sidebar, detail, and inspector](https://learn.chatgpt.com/use-cases/macos-sidebar-detail-inspector.md)
- [OpenAI Build macOS Apps plugin](https://github.com/openai/plugins/tree/main/plugins/build-macos-apps)

Use these as design guidance, not as substitutes for Apple's API documentation, this repository's RFDs, or local safety rules. Axo-specific architecture is described in [`RFD0004`](../../../docs/rfds/RFD0004-axo-macos-application-architecture.md), and the product feature proposal is [`RFD0005`](../../../docs/rfds/RFD0005-axo-native-workbench-feature-set.md).

## Scene and ownership model

- Choose the scene model before shaping views. Use a `WindowGroup` for repeatable primary workbench windows and a separate `Settings` scene for app preferences. Add a menu-bar extra or utility scene only for a concrete product need.
- Treat each workbench window as a viewport with a stable `WindowID`, its own frame/restoration and sidebar state, and its own selected workspace/session. All windows share Axo's workspace/session catalog, coordinator, session controllers, pane identities, and process owners.
- Keep durable workspace/session state in `AxoCore`; use scene/window state (for example `@SceneStorage` where appropriate) for viewport state, and `@AppStorage` or Axo's settings model for user preferences. Do not make a SwiftUI wrapper, `NSWindow`, or AppKit delegate a competing source of truth.
- Opening, closing, restoring, or selecting in a window must not create, stop, clone, or retarget a Pi/shell process.
- Same-session multiwindow terminal rendering is a technical feasibility gate. Validate the pinned surface API. Never duplicate a Pi writer or process to simulate another view; document the tested fallback if simultaneous rendering is unsupported.

## Desktop workbench UI

- Prefer persistent sidebar/detail navigation with stable, explicit selection; use `NavigationSplitView` when it fits the current workbench, but do not rewrite a working native AppKit outline/source list solely to change frameworks.
- Keep sidebar rows light and scannable: normally one icon, a title, and at most one short secondary line. Put dense metadata in the detail surface or an inspector only if a real use case justifies the lost terminal space.
- Prefer system sidebar/window materials, standard controls, and semantic/adaptive colors. Keep custom styling for specific Axo product needs, especially the terminal surface; avoid opaque backgrounds or card-heavy rows by default.
- Make important actions discoverable through menus, scene commands, toolbars, and keyboard shortcuts. Route all entry points through the same typed command path with captured `WindowID` and session/pane IDs where relevant. Do not make a critical action gesture-only.
- Keep a dedicated `Settings` scene for app-level appearance, shortcut, voice, and notification preferences; do not push global settings into the workspace/session navigation stack.
- **Main-workbench collapse means a compact, usable icon rail, not hiding navigation or reducing it to zero width.** Retain workspace/session navigation with accessible names, selection cues and tooltips, plus Create and a bottom-aligned expand control. Settings is accessed through the application menu and Cmd+Comma rather than a compact-rail gear shortcut. Preserve the expanded width separately; compact resize must not overwrite it. Keep View → Toggle Sidebar (⌃⌘S) and any window-toolbar toggle on the same preference; do not overlay the only expand control on the hosted detail surface. AppKit's reserved `.toggleSidebar` toolbar item routes to `NSSplitViewController` and can override target/action; custom splits need an explicitly routed ordinary toolbar item. Run `bash scripts/check-mac-sidebar.sh` for owned hidden-window action and rail-layout checks; these do not prove live full-window interaction.
- Settings collapse also means a usable 56-point rail, not hidden navigation. Keep all three section destinations, selected page, separately retained expanded width and a bottom expand control. The Settings preference is independent of the main sidebar. In AppKit-created utility windows, embed through `NSHostingController` and respect toolbar/content safe areas; validate both layouts.
- New Session is a direct creation/execution action: no name or progress modal and no second Open Session action. Select committed work immediately, keep startup/error/unknown outcomes inline, and let Pi's `axo_set_title` set canonical conversation names. The required terminal layout is Pi left and an independently starting regular shell right; a metadata record or running PID is not operational acceptance. The user selected automatic new-session creation on every genuinely empty startup, not only first launch. Require authoritative empty work/runtime state and reconcile pending/uncertain receipts first; existing-record restoration and ordinary reconnect do not launch work. Standalone Pi/shells use daemon-captured HOME, while project Pi/shells use the locally approved selected folder.
- A keybinding recorder must distinguish key events from `flagsChanged`: character accessors such as `charactersIgnoringModifiers` raise an AppKit exception on modifier-only events. Capture the modifier's key code on press, not release; cancel on focus loss or teardown. `bash scripts/check-mac-voice-keybinding.sh` exercises this in an owned hidden window without Accessibility or another app's events.

## AppKit boundary

- Use SwiftUI scenes/views first for scene composition, state, selection, standard controls, commands, and toolbars.
- Add only the smallest AppKit bridge needed for a named capability gap, such as Axo's terminal `NSView`/`NSTextInputClient`, first-responder/IME behavior, specialized menu validation, panels, or a focused window hook.
- SwiftUI remains the source of truth for selection and observable app state. A representable coordinator owns delegate/lifecycle glue, not a second app architecture.
- Never let view reconstruction or window attachment define terminal-surface/process ownership. Preserve explicit pane/session identity and validate stale callbacks.
- The Axod terminal surface launches only the captured bundled `axod terminal-attach` presentation child; keep Pi/shell ownership in the daemon. Pinned Ghostty's macOS shell-command wrapper already supplies `exec -l`: do not prefix the embedding command with another `exec`. Retain surfaces by exact machine/host/session/pane/runtime identity, never retarget from the current global selection, and reject competing interactive viewports rather than duplicating execution.
- Ghostty's outer-PTY resize is asynchronous. A surface-size setter is not a barrier for later terminal input. `bash scripts/check-mac-terminal.sh` runs owned offscreen native checks plus a Rust-owned actual CLI/daemon/full-surface fixture for Unicode, eventual geometry and non-destructive disposal. Build the Mac target and debug helper/CLI first; `AXO_LOCAL_DAEMON_BINARY` selects the exact packaged helper for owned checks. These component fixtures do not establish daily-workbench, real OS IME, images, multiwindow, live restart or VT recovery acceptance. Never dump terminal bytes while diagnosing them.

## Build, run, test, and package

- Keep the workflow shell-first. Axo's generated Xcode project should be built/tested with `xcodebuild`; use `swift test` for Swift packages and focused package tests.
- Run the smallest useful build or test target first, then expand only if needed. Classify failures accurately (compile, link, assertion, crash, flake, environment/toolchain, or signing).
- Use `scripts/build-mac.sh` and the sibling [axo-macos-packaging skill](../axo-macos-packaging/SKILL.md) for the repository's bridge build and `dist/Axo.app` packaging requirements.
- A local build/package command must not silently terminate or relaunch an active Axo/Pi process. App launch, live restart, bundle replacement, archive, signing, and notarization are distinct operations; get required operational consent before a live restart. When launching for validation, use the `.app` bundle rather than a raw GUI executable.
- Local launch success does not prove distribution readiness. When shipping is in scope, keep a manual Xcode archive path for one-off checks and a repeatable scripted archive/notarization path; separately inspect the app bundle, entitlements, hardened runtime, and signatures (`codesign`, `plutil`, and Gatekeeper checks as appropriate). Use App Store Connect CLI tooling only if that upload route is selected.

## Runtime observability

- Prefer Apple's unified logging through `Logger`, with the bundle identifier as subsystem and small categories such as `Windowing`, `Sidebar`, `Commands`, `Settings`, or `Runtime`.
- Log high-signal lifecycle and user-action boundaries and verify them with `log stream` or Console when behavior needs evidence. Avoid noisy per-view-update logging.
- Never log prompts, terminal output, transcripts/audio, credentials, environment values, clipboard content, or full private configuration data.

## Implementation checklist

- Read current code, relevant RFDs, and repository status before editing; preserve unrelated work.
- Identify whether state is app-wide, window-scoped, preference-scoped, durable work data, or view-local.
- Ensure menu, toolbar, keyboard, and palette actions share a typed, destination-aware command path.
- Test at least two windows for independent selection over one shared catalog; test close/restore without process restart.
- Verify keyboard, focus, IME, accessibility, and terminal input after changes to scene or representable boundaries.
- Report exact build/test/log commands and distinguish validated source/build/package/live-app status.
