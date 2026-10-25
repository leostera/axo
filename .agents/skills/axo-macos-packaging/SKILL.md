---
name: axo-macos-packaging
description: Build, validate, and deliver Axo's Finder-launchable Mac app. Use after any Mac app, bundled helper, or Pi extension change that affects the shipped development app, and when updating dist/Axo.app.
---

# Axo macOS packaging

Resolve paths from the Axo root (`../../..`). **Repackage `dist/Axo.app` after every validated Mac app, helper or Pi-extension change.** A Bazel build output is not delivery. Follow the [native app](../axo-macos-native-apps/SKILL.md) skill for structure and tests.

## The package

- One signed `dist/Axo.app` built from `//apple/AxoMac:AxoApp` (the `AxoMacMain` entry over the `AxoMac` library; never `AxoMacTestHost`). It embeds `Contents/Helpers/axod`, the Pi extension at `Contents/Resources/AxoPi/`, Ghostty resources/terminfo and the per-user LaunchAgent plist `dev.leostera.axo.axod.plist`. Vanilla Pi is an external runtime dependency.
- Signed with an Apple Development or Developer ID identity; not notarized. Ad-hoc signing is unsupported because launchd must accept the helper. App and helper must share a team.
- Minimum macOS is 14.0 for both executables (`build-mac.sh` checks `vtool` minos against `LSMinimumSystemVersion`).
- `DaemonController` registers the LaunchAgent through `SMAppService` and restarts axod when its build number differs from the app's.

## Build and verify

```bash
cd <axo-root>
bazel test //apple/AxoMac:AxoMacTests //apple/AxoMac:TerminalWorkbenchE2ETests \
  //apple/AxoMac:AxoAppSelfTestTests //apple/AxoProtocol:AxoProtocolTests //apple/AxoClient:AxoClientTests \
  //apple/AxoClient:AxoClientDaemonInteropTests //apple/AxoDaemonManager:AxoDaemonManagerTests \
  //apple/AxoSearch:AxoSearchTests \
  //crates/axod:rpc_tests
./scripts/build-mac.sh
codesign --verify --deep --strict dist/Axo.app
plutil -p dist/Axo.app/Contents/Info.plist | grep -E 'CFBundleVersion|AXOGitCommit'
```

- `scripts/build-mac.sh` selects the single valid signing identity (or `AXO_MAC_SIGNING_IDENTITY`), reserves the next build number under `~/Library/Application Support/Axo/build-number`, builds the Pi extension and a stamped `-c opt` app, embeds the extension, stamps `AXOGitCommit` (`-dirty` when the tree has changes or untracked files), checks build numbers and minimum OS, signs helper then app, and verifies team identity.
- `scripts/replace-app.swift` swaps the staged bundle into `dist/Axo.app` atomically and keeps the previous bundle in the staging directory for rollback. Never delete `dist/Axo.app` first.
- Run affected Rust (`cargo test -p axo-server --lib`, `bazel test //crates/...`) and TypeScript (`npm --prefix packages/pi-axo test`, `npm --prefix packages/axo-api run schema:check`) checks for daemon or extension changes.
- For a delivered build, report the build number, `AXOGitCommit`, signature status and which test lanes ran.

## Runtime safety

- Packaging is disk delivery, not deployment: running Axo and axod keep their mapped code. Never close, restart or signal discovered Axo/Axod processes; a restart needs the user's direction.
- Do not run axod as root, and never touch the user's Axod state (`axo_server::default_server_directory()`), Pi transcripts, clipboard or Application Support state while packaging or testing. Tests use isolated fixtures.
- Do not run visual UI tests while the user's Axo is open; the runner refuses, and its safeguard must not be bypassed.
- Isolated component or fixture success does not prove ServiceManagement handoff, Finder launch, physical IME or notification delivery.
