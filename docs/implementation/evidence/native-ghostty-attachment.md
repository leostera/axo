# Native Ghostty attachment checkpoint

This checkpoint is **component evidence**, not full supported-workflow acceptance.
No inventory acceptance gate is closed.

## Exact versions

- Implementation source: `ab417fd7399259b13c97b3b3af24d2c8db11be59`, committed and
  pushed on `main`.
- Package: `dist/Axo.app`, build **118**, `AxoBuildCommit` exactly the source above.
- Bundled helper: **`0.1.0 (ab417fd7)`**; strict deep code-signature verification
  passes. The upstream MIT notice is present at `Contents/Resources/LICENSE.txt`.
- Ghostty tracked checkout: `7ec9e26a29399b30ef78f06985fc75045b3cecb6`, unmodified.
  Characterized static universal archive SHA256:
  `7fe3dda81082531ce1f920abb38834a5dc7e46c291d68969c7559f28eb360ab5`.
  This identifies the tested artifact; it is not a reproducible-build/ABI claim.
- Version-recording documentation changes after that implementation commit do
  not alter the bundled executable. The live helper/app version was not changed.

## Implementation

The Axod Mac target links the pinned full Ghostty surface and upstream split
primitives, with their MIT notice in the bundle. The closed `TerminalLaunch`
factory constructs only the bundled `axod terminal-attach` command, capturing
machine/host/session/pane/runtime. It cannot construct a Pi/repository launcher
or an ordinary login-shell launch. Ghostty supplies its own `exec -l` wrapper.

Assigned running PTYs render in the default terminal lane; canonical conversation
viewing is separately selectable. Views are retained in a bounded 32-surface
presentation cache; view reconstruction reuses the same surface. Session/runtime
changes cannot display an old attachment as the new input destination. A competing
interactive viewport is rejected. Frontend exit and disposal are not durable work
completion, pane removal or replay permission.

The AppKit host supplies owning-window focus/occlusion/backing scale, modifier-only
event handling and IME preedit. Terminal OSC title/cwd are not routing/naming/path
authority. URL opening is bounded, http/https-only, credential-free and user-driven.

## Validation

- Mac target compilation/linking and atomic packaging pass.
- Both native component fixtures were rerun against the **actual build118 bundled
  helper**, not just the debug executable; both pass.
- Actual packaged-helper AxoCore lane: **81 tests, zero skips/failures** in owned
  private fixture roots. No shared AxoCore source changed; no new phone build is
  claimed.
- `scripts/check-mac-terminal.sh`: owned offscreen full-surface creation/cache,
  modifier and preedit checks, missing-discovery failure without fallback, safe URL
  parser checks and disposal.
- Rust-owned actual `axo` → `axod serve` → daemon PTY → transport child → full
  Ghostty surface fixture: screen text includes initial output and submitted
  Japanese/emoji, native resizing reaches actual inner PTY geometry, and disposing
  the surface leaves exactly one unchanged running runtime with its original
  receipt and no attached presentation lease.
- Resize is eventual: Ghostty applies outer-PTY geometry asynchronously. The test
  observes each distinct synthetic probe before submitting another; it does not
  replay uncertain input or infer ordering from dispatch.
- Serial locked/offline Rust: 92 library, interactive Pi 1, local sessions 2,
  managed public 1, public CLI 6, relay config 4; zero ignored/skipped cases.
- Clippy all targets with warnings denied, fmt and diff checks pass.
- Swift protocol: 33 cases, 1 existing relay-environment skip, zero failures. The
  skipped deployed-relay contract is **not** passing evidence.
- Pinned split package: 50 Swift Testing cases pass.
- Owned sidebar, owner-lock and voice-keybinding checks pass.
- Protocol properties 4 and API properties 2 pass.

## Open gates and operational limits

The independent default HOME/project shell policy, immediate complete Pi-left /
shell-right creation, authoritative-empty automatic startup, full pane/window
commands/restoration, real OS IME composition, visible workbench focus/resize,
clipboard/drop, graphics, accessibility, feature queries and full VT snapshot/live
recovery remain open. A missing shell is shown honestly, not fabricated as a
terminal. Untruncated raw replay is not screen restoration; truncated replay still
fails while preserving work. Cache admission fails safely at its bound rather than
silently evicting recoverable screens.

These owned offscreen checks do not prove actual packaged-workbench or live-service
acceptance. No live app/helper restart, historical PID signal, uncertain replay,
credentials/deployment change or device installation was performed. The previous
signed bundle is retained by atomic packaging for rollback.

Temporary validation logs (not acceptance archives):
`/tmp/axo-native-attachment-{build,rust,clippy,protocol,layout,sidebar,owner,voice,protocol-properties,api-properties,package,packaged-surface,core}.log`.
The unbundled development native fixture log is
`/tmp/axo-native-terminal-fixture.log`; assertions never dump terminal text.
