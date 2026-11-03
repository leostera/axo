---
name: axo-macos-packaging
description: Build, validate, and deliver Axo's Finder-launchable Mac app. Use after any Mac app, bundled helper, or Pi extension change that affects the shipped development app, and when updating dist/Axo.app.
---

# Axo macOS packaging

Resolve paths from the Axo root (`../../..`). **Every `bazel build` puts the signed app at `dist/Axo.app`** (`dist.mac_app` in `config.json`), swapping it in only when it changed; run one after every validated Mac app, helper or Pi-extension change. Follow the [native app](../axo-macos-native-apps/SKILL.md) skill for structure and tests.

## The package

- One signed `dist/Axo.app` built from `//apple/AxoMac:AxoApp` (the `AxoMacMain` entry over the `AxoMac` library; never `AxoMacTestHost`). It embeds `Contents/Helpers/axod`, the Pi extension at `Contents/Resources/AxoPi/`, Ghostty resources/terminfo and the per-user LaunchAgent plist `dev.leostera.axo.axod.plist`. Vanilla Pi is an external runtime dependency.
- Signed with the team's Apple Development or Developer ID identity (`apple.team` in `config.json`), hardened runtime and secure timestamp; not notarized. Without one the build signs ad hoc and says so in `bazel-bin/report.txt`, but launchd needs a real signature for the helper. App and helper share a team.
- Minimum macOS is `apple.macos_min` in `config.json` (14.0) for both executables; `//apple/AxoMac:package_test` checks it, the build numbers, the team and the signature against config.
- `DaemonController` registers the LaunchAgent through `SMAppService` and restarts axod when its build number differs from the app's.
- **Bump `builds.axod` in `config.json` in its own commit every time anything axod runs changes (`crates/axod`, `axo-server`, `axo-relay` or any crate they use) before building the app.** Otherwise Axo keeps the running axod and the change never reaches the Mac. Bump `builds.mac` when a build should be told apart from the last one (always before publishing).
- **Every publish raises the semantic version's minor** (`version` in `config.json`: 0.1 → 0.2 → 0.3), as well as `builds.mac`, in one commit before `bazel run //:publish`, which refuses an app whose version or build is not above the published one. The version is major.minor only. Every build keeps its own build number; About shows the semantic version, the commit hash and the build number.

## Build and verify

```bash
cd <axo-root>
bazel test //apple/... //crates/... //packages/pi-axo/...
bazel build //...
cat bazel-bin/report.txt
```

- The report says how the app was signed, whether `dist/Axo.app` was installed, and the build numbers and `AXOGitCommit` (the commit at HEAD; the build does not mark changes). `package_test` runs with the tests.
- `dist/Axo.app` is swapped in atomically; the previous bundle is kept at `dist/.Axo.app.previous` for rollback. Never delete `dist/Axo.app` first.
- For a delivered build, report the build number, `AXOGitCommit`, signature status and which test lanes ran.

## Publishing

`bazel run //:publish` uploads the signed app from a checkout without changes to the `axo-cdn` bucket (`publish` in `config.json`), served at `https://axo.leostera.dev/cdn/Axo.app`; `curl -fsSL https://axo.leostera.dev/install | sh` installs it on another Mac (see `sites/axo.leostera.dev/README.md`). Publish only when Leo asks. Never copy the bundle to another Mac through a browser or AirDrop: it gets quarantined and translocated, and then it cannot register axod.

## Runtime safety

- Packaging is disk delivery, not deployment: running Axo and axod keep their mapped code. Never close, restart or signal discovered Axo/Axod processes; a restart needs the user's direction.
- Do not run axod as root, and never touch the user's Axod state (`axo_server::default_server_directory()`), Pi transcripts, clipboard or Application Support state while packaging or testing. Tests use isolated fixtures.
- Do not run visual UI tests while the user's Axo is open; the runner refuses, and its safeguard must not be bypassed.
- Isolated component or fixture success does not prove ServiceManagement handoff, Finder launch, physical IME or notification delivery.
