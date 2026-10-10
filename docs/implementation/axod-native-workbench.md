# Axod-only native workbench cutover

## Acceptance bar

The operator wants `dist/Axo.app` to replace the former daily workbench so Axo can be used to develop Axo. Source builds, metadata browsing, and cloud registration do not establish that parity. Never retire a working client merely because its replacement builds. Repackaging does not authorize stopping accepted daemon/Pi work.

## Ordered implementation

1. **Native work records:** workspace/session create and rename, captured destinations and revision, approved directory selection, durable command reconciliation without redispatch. Wire menu, toolbar and sidebar actions through one path. Configuration/onboarding must authorize directories and installed ambient Pi explicitly; an empty approved-directory catalog is not permission to import old configuration.
2. **Managed Pi:** fresh admission/exact resume, branch-aware history, send/steer/cancel, owned questions, tool details, per-conversation drafts, source-bound observation and reconnect. Restore metadata only; never replay messages or adopt previous processes.
3. **Terminal data plane:** implement a separate bounded local attachment protocol over actual owned PTYs, not terminal bytes inside metadata/cloud RPC. Prove input, output, resize, detach, EOF, backpressure, renderer capability and IME. Reuse the existing native terminal/split foundations; backlog is not a VT snapshot.
4. **Pane lifecycle:** typed local add/remove, Cmd+D/Cmd+Shift+D splits, captured focus, Cmd+W exact semantics, detach versus termination, durable completion-gated removal, state restoration and sibling isolation.
5. **Workbench parity:** window-scoped selection and focus, independent windows over shared work, keyboard/menu actions, persistence, notifications, appearance. Inventory archive/duplicate, files/attachments and voice against daemon capabilities; implement missing authority rather than adding nonfunctional UI or reviving the deleted bridge.
6. **Service updates:** Settings shows bundled and actual running versions. An enabled SMAppService is not proof that launchd resolves the current bundle/helper. Check the resolved executable when validating a live update; stale registrations can still resolve moved/trashed bundles. No automatic unregister/restart of an owner with accepted work. Establish explicit, safe service repair/update semantics.

## Current evidence and gaps

- Rust CLI/local/cloud managed Pi and shell lifecycle have isolated acceptance; the native app has metadata browsing and initial managed chat controls.
- The first native workspace/session creation pass now uses approved-directory selection, captured target/revision, shared request/result validators, saved unresolved command IDs and explicit read-only reconciliation. Sidebar and keyboard/menu entry points share it. This is source/build progress, not native interaction or crash-durability acceptance. Rename and directory/Pi onboarding remain absent.
- Swift session parsing now includes typed, bounded shell-pane projections and checks session/pane ownership, unique IDs and exact terminal references. Previously Swift rejected the daemon's `shellPanes` field; empty-catalog builds did not expose this.
- Local terminal attachment is a backend gap, not just an unwired view.
- Archive/duplicate, attachments and explicit runtime/daemon stop need backend capability work.
- API deployment and physical iOS installation succeeded during the baseline deployment. Mac packaging succeeded, but live helper replacement was **not** verified: the registered helper resolved a trashed older app and did not expose `axo.host.get`. Do not call this a completed live Mac upgrade or confirmed production cloud registration.

## Validation

Require typed request/result and captured-target tests; actual public-RPC/PTY acceptance; native build and signed `dist/Axo.app`; then explicit human/native operational drills. Exercise create/start/send/tool/history, pane input/split/resize/close, window detach/restore and reconnect without duplicate execution. Keep live deployment, authentication, Accessibility and device acceptance distinct from compilation and fixtures.
