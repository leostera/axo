# RFD0054 - Axo: native Linux desktop

- Feature Name: `linux-desktop`
- Status: Proposed (standalone GTK/Ghostty embedding prototype implemented)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0021](RFD0021-bazel-only-build.md) (Linux desktop target)

## Summary

Build `linux/AxoDesktop` as a Rust/GTK4 frontend over Axo's existing Rust daemon, protocol, session storage and PTY machinery. Keep the Swift macOS frontend. Use the pinned Ghostty GTK widget for rendering rather than VTE or a second terminal implementation. Grow from an independently tested embedding spike into a daemon-attached terminal, then a workbench. Share product/session policy in Rust rather than translating the Swift backend into an independent Linux implementation. Installation and privileged approval/input support remain explicit gates, not consequences of having a GTK window.

## Motivation

The Linux daemon can run real Sessions but has no native workbench. A standalone shell proves rendering, not the ability to view those Sessions. The Mac app also contains substantial Swift client-side coordination; having a shared daemon does not mean all application logic is already shared. Copying each Swift model into GTK would create two independently evolving products.

## Guide-level explanation

Opening a Session shows its daemon-owned shell. Quitting the desktop app detaches its views; the Session continues running and can be reopened with its history. Explicitly closing a shell or archiving a Session is different: the app checks busy state, asks when necessary, then calls the existing daemon operation.

For example, opening shell 105 connects to `attach.sock`, sends `105\n`, reads the eight-byte big-endian replay length and receives one PTY master descriptor. The socket supplies replay followed by live output; the master is used only for input, resize and terminal queries. Neither a renderer nor a second client consumes the daemon's PTY output directly.

The initial prototype deliberately does something narrower: it owns a local command/PTY through Ghostty and never connects to the paired daemon. Its standalone status is visible in the window and command help. This remains a development mode, not an alternative Session backend.

## Reference-level explanation

### Ownership and boundaries

- `crates/axo-server`, `axo-agent`, `axo-store`, `axo-relay` and `axo-pty` remain authoritative for Sessions, agents, durable state, account routing and PTY ownership.
- Reuse `axo-protocol` methods/types/capability negotiation and `axo-pty::attach`; do not invent a Linux wire protocol or shell out to the generated CLI for GUI operations.
- The new CLI's bounded transport currently lives in `crates/axo-cli/src/transport.rs`. When a reusable request/event client is needed, extract a shared Rust implementation and adapt the CLI, rather than copying the private CLI transport into the desktop. Descriptor attachment already has a shared implementation.
- `linux/AxoDesktop` owns GTK widgets, desktop integration and its private Ghostty GTK bridge. It must not own a second database, relay implementation, agent scheduler or session lifecycle.
- New reusable workbench policy belongs in Rust under `crates/`: selection reconciliation, close intent, layout write ordering, activity/unseen grouping and command availability. Native shells own focus, presentation, dialogs and OS-specific APIs. The existing Swift models are the behavioral reference; their migration can be incremental without rewriting the Mac UI.
- Ghostty's GTK Application/Surface classes are internal APIs, not its Apple rendered C embedding. The bridge is a small pinned-source adaptation. Mac XCFramework patch selection/builds stay separate.

### Feature inventory and cutover map

Reference: Mac source at Axo 0.64, commit `24e8a85056222c809f8ba43fe50f13b4faa86529`. This is a source inventory, not a claim that the entire Mac UI was interactively retested.

| User-visible behavior | Current reference | Linux implementation boundary |
| --- | --- | --- |
| Startup, readiness splash, reconnect and app-lifetime catalog observation | `App/AxoApp.swift`, `App/LaunchBoot.swift`, `App/AxoWorkbench.swift`, `Sessions/TerminalCatalogSync.swift` | GTK readiness/error presentation; one shared connection/subscription owner, not one loop per widget |
| Local Sessions; new at home/in folder/current context; rename, archive and reopen | `Sessions/AxodClient.swift`, `Workbench/WorkbenchSidebar.swift` | Existing daemon methods; GTK sidebar/folder chooser and explicit action failures |
| Pi plus shell panes; split right/down; focus/navigation and persisted layout | `App/AxoApp.swift`, `Sessions/TerminalLayoutWriter.swift`, `Sessions/ViewportReporter.swift` | Existing protocol/layout authority; share ordering/coalescing policy; GTK paned widgets and focus |
| Attach, replay/live output, resize, reconnect and stale-attach suppression | `Terminal/Surface/GhosttySurfaceNSView.swift`, `AxoClient/TerminalAttachment.swift` | Shared Rust attachment client plus GTK external-I/O bridge; descriptor/generation ownership is mandatory |
| Busy/unknown close confirmation; automatic Pi recovery only when safe | `Sessions/CloseConfirmations.swift`, `Sessions/AutomaticPiRestarter.swift` | Shared close/recovery policy, native dialogs, daemon auto-restart checks; never infer idle from missing data |
| Pinned/Active/Earlier groups; configurable order, unseen markers, stable order under pointer | `Workbench/WorkbenchSidebar.swift`, `Settings/SessionsSettingsView.swift` | Shared policy over daemon catalog/activity with local preferences; GTK list rendering |
| This host/another host/all Sessions; closing a remote view versus its owning Session | `Sessions/AxodClient.swift`, `Workbench/WorkbenchSidebar.swift` | Existing peer-session operations; host-qualified identity and platform-neutral copy |
| Command palette: Session/pane search, folder commands, split/close/settings/sidebar; GitHub clone entry | `Palette/CommandPaletteCatalog.swift`, `App/AxoApp.swift` | Share command identity/availability/search policy; GTK palette and folder chooser; captured IDs for destructive choices |
| Terminal copy/paste, select-all, undo/redo, find, pointer/scroll, IME, links, bell/attention and accessibility | `Terminal/GhosttyRuntime.swift`, `Terminal/Surface/*`, `Terminal/UntrustedURL.swift` | Reuse native Ghostty GTK behavior where equivalent, but audit Axo-specific policy and build acceptance tests; no blanket parity claim |
| General/Appearance: scroll multiplier, system/light/dark, idle sleep inhibition, shell command and daemon status | `Settings/GeneralSettingsView.swift`, `Settings/SettingsView.swift` | Shared settings parsing; GTK controls; Linux idle-inhibit/service adapters, not copied IOKit/launchd calls |
| Sessions/Agent: grouping, idle Pi limits, agent command, safe automatic recovery | `Settings/SessionsSettingsView.swift`, `Settings/SettingsView.swift` | Existing daemon configuration plus shared preference/recovery policy |
| Remote Access: pairing code/deep link, connect/retry, connection age/errors, host/platform | `Settings/RemoteAccessSettingsView.swift`, `App/PairingLinkRouter.swift` | Existing relay/link methods, strict code/URL parsing and Linux desktop URI registration; never log codes |
| Questions and secure forms; first answer from any device wins | `Sessions/ElicitationsModel.swift`, `App/QuestionsPanel.swift` | Block local privileged answers until a Linux client-authentication design exists; preserve remote approval routes and secret protections |
| Menu-bar status, pending-question indication, reopen/hide/quit distinctions and mascot interactions | `App/AxoApp.swift`, `App/FloatingAxo/*`, `App/Mascot/*`, `App/Squishy/*` | Native Linux status integration where supported; GTK workbench must work without a tray; mascot behavior is later, not a dependency of Sessions |
| About/version, update checks/banners, captured-release progress and consent before replacement/restart | `App/AppUpgradeModel.swift`, `App/AppUpgradeNotifications.swift`, RFD0048 | Shared release/install contract with Linux authenticity/service adapters; no reuse of Apple code-signing assumptions |

Paths in this table are relative to `apple/AxoMac/Sources/AxoMac`, except `AxoClient/TerminalAttachment.swift`, which is under `apple/AxoClient/Sources/AxoClient`.

### Invariants

1. Axod is the sole reader of a shell's PTY master. Ghostty reads only its attachment output socket. Never change shared PTY file-status flags.
2. All received/duplicated descriptors are close-on-exec; reject malformed/truncated/multiple descriptor messages without leaking any delivered descriptors. Reset handshake-only socket timeouts before streaming.
3. Closing/destroying an attached widget cannot send a signal to or terminate its daemon-owned shell. Native Ghostty standalone close behavior is not automatically correct for an attachment.
4. Replay must initially meet its original grid. A placeholder GTK size must not reflow history before the real layout is known. Do not reuse the Apple initial-size solution without implementing its GTK equivalent.
5. Attach work runs off the GTK main thread. Cancelled/superseded generations close their resources and cannot install a stale surface. Capability negotiation precedes unsupported operations; reconnect never blindly repeats writes.
6. Widgets retain their engine through native finalization, including before realize. Destroy widgets and disconnect callbacks before global renderer teardown. GTK access is main-thread-only.
7. Unknown busy state asks; closing a remote view is not archiving a remote Session. One layout writer per Session prevents older writes landing after newer ones.
8. Same UID, a private path, a familiar executable name or a self-asserted role is not privileged client authentication. `Signer::AxoApp` continues to fail closed outside macOS. Never route local calls as `Peer::Relay`.
9. Keep computer-use GNOME guards and Linux secure-input refusal. A native GTK client does not make focus/origin-bound secret entry safe by itself.
10. Treat terminal output/links as untrusted. Custom-scheme/executable-file handling and clipboard/paste policy need an Axo-equivalent audit before enabling a real-client surface; do not assume upstream GTK defaults match the Mac adapter.

### Implementation sequence

Implement serially:

1. Keep the standalone rendering spike isolated and reproducible. Inspect its owned-fixture screenshot; run lifecycle/config-isolation and PTY input/resize tests.
2. Harden/reuse the existing attachment client, then expose GTK external I/O with correct descriptor lifetime, initial grid, failure and detach semantics. Prove replay, input, resize and frontend restart against an isolated real daemon, with no paired-runtime restart.
3. Add the smallest catalog-backed workbench: local Session list, selected Session and panes, create and reconnect. Share transport/policy rather than wrapping the CLI. Grow close/archive/reopen and persisted split layouts through the existing operations.
4. Add grouping, palette, terminal affordances, settings and peer hosts against the feature map. Match intent/behavior, not literal macOS shortcut glyphs or UI layouts.
5. Complete per-user Linux install/service/storage/release contracts and native desktop integration. Stage upgrades separately from restart consent; retain rollback and data on uninstall.
6. Add privileged local approval/input only after a reviewed Linux trust design and field/origin guarantees. Do not show working-looking approval buttons that the daemon must refuse.

### Tests and compatibility

Use existing Rust unit/conformance tests for shared behavior and an owned Xvfb/D-Bus/GTK fixture for actual rendered output, input, resize and widget teardown. Add independent tests for renderer close versus Session close, replay-grid preservation, stale attach completion, reconnect and offline/unsupported states. Test receiving descriptor CLOEXEC/truncation/error cleanup at the shared IPC boundary, not just through GUI happy paths.

The spike is tested with Ubuntu 26.04/x86-64, GTK 4.22.4, libadwaita 1.9.1 and software OpenGL. This is not a portable release floor, hardware-GPU acceptance, native GNOME Wayland acceptance or comprehensive accessibility acceptance. Rootless development library paths/native CPU defaults are not release packaging choices. Do not migrate storage or restart/publish the paired runtime as part of GUI testing.

## Drawbacks and alternatives

- Internal Ghostty GTK APIs cost pin-specific maintenance; a future upstream GTK embedding API would be preferable. A portable VT library alone is not a rendered terminal widget.
- A single cross-platform rewritten UI reduces native adapters but discards the existing Swift frontend and its OS integration. Two native frontends over shared Rust are the chosen direction.
- VTE or a browser renderer is easier to embed but introduces a different terminal behavior/renderer. Keep that as a fallback only if the Ghostty integration cannot meet ownership and replay requirements, not as a silent substitution.
- Translating every Swift model into GTK is initially tempting but creates duplicated policy. Extract only the shared policy needed by each vertical slice, with the existing Mac tests as references.
- Doing nothing leaves Linux usable only through remote/CLI clients despite the working daemon.

## Unresolved questions

Before privileged UI: choose a Linux application-authentication and approval trust design; this RFD deliberately does not grant authority. Before release: declare the supported distribution/library/CPU matrix, verify native Wayland/GPU/accessibility behavior, and settle artifact authenticity plus install/update lifecycle. During attachment implementation: choose the smallest GTK initial-grid hook and resource-owning external-I/O interface without changing the Mac embedding contract.
