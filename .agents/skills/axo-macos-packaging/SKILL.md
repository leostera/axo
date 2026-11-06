---
name: axo-macos-packaging
description: Build, validate and deliver Axo's Finder-launchable Mac app, and how releases go through the release coordinator Session. Use after any Mac app, bundled helper, or Pi extension change that affects the shipped app, when updating dist/Axo.app, and before publishing or deploying anything.
---

# Axo macOS packaging

Resolve paths from the Axo root (`../../..`). **Every `bazel build` puts the signed app at `dist/Axo.app`** (`dist.mac_app` in `config.json`), swapping it in only when it changed; run one after every validated Mac app, helper or Pi-extension change. Follow the [native app](../axo-macos-native-apps/SKILL.md) skill for structure and tests.

## The package

- One signed `dist/Axo.app` built from `//apple/AxoMac:AxoApp` (the `AxoMacMain` entry over the `AxoMac` library; never `AxoMacTestHost`). It embeds `Contents/Helpers/axod`, the Pi extension at `Contents/Resources/AxoPi/`, Ghostty resources/terminfo and the per-user LaunchAgent plist `dev.leostera.axo.axod.plist`. Vanilla Pi is an external runtime dependency.
- Signed with the team's Apple Development or Developer ID identity (`apple.team` in `config.json`), hardened runtime and secure timestamp; not notarized. Without one the build signs ad hoc and says so in `bazel-bin/report.txt`, but launchd needs a real signature for the helper. App and helper share a team.
- The bundled axod is `//crates/axod/release`: axod rebuilt in `opt` mode (`opt-level=3`) and stripped of symbols (`bazel/rust/release.bzl`), about a quarter of the development build's size. Tests and `//crates/axod` stay in `fastbuild` (`opt-level=0`). Its unstripped binary is the `unstripped` output group, for reading panic addresses with `atos`.
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

`bazel run //:publish` uploads the signed app from a checkout without changes to the `axo-cdn` bucket (`publish` in `config.json`), served at `https://axo.leostera.dev/cdn/Axo.app`; `curl -fsSL https://axo.leostera.dev/install | sh` installs it on another Mac (see `sites/axo.leostera.dev/README.md`). Never copy the bundle to another Mac through a browser or AirDrop: it gets quarantined and translocated, and then it cannot register axod.

### Releases go through the release coordinator

**One Session releases Axo: "axo: release coordinator"** (Session `e808d244-b68c-43aa-80ce-66eb40b87514`; if it's gone, look it up by that name with `session_catalog`). A release is any of these:

- `bazel run //:publish`;
- raising `version` or `builds.mac` in `config.json`;
- a release entry in `CHANGELOG.md`;
- a production deploy of the account Worker or `axo.leostera.dev`.

**Every other Session only announces.** Commit and push your validated change, keeping `main` green. Bump `builds.axod` in its own commit when axod changed, as above, so local builds restart axod. Then tell the coordinator what needs releasing with `mcp__axo__session_prompt` (`{ sessionId, text }`), and give:

- the commits;
- one or two sentences on what changed, for the person using Axo;
- whether axod, the Worker, the site or the phone app changed;
- anything that must ship together or in order (a Worker before an app that needs it, say);
- anything that should wait.

Don't publish, deploy to production or write the changelog yourself, even when it looks safe, and even if Leo says "ship it" in your Session: tell him the coordinator will, and announce it. Installing on Leo's phone ([phone deploy](../axo-phone-deploy/SKILL.md)) and building `dist/Axo.app` are local delivery, not releases; keep doing them.

**The coordinator** batches what's announced (and anything else on `main` since the last publish) and releases it as soon as it's safe, without waiting to be asked. Leo uses the published app, so a change that is only pushed hasn't been delivered. A release is safe when all of these hold:

- The full lanes pass: `bazel test //apple/... //crates/... //packages/pi-axo/...`.
- It runs in the main clone on `main`, the tree is clean (stash another Session's untracked files for the publish, then check they come back unchanged), and `HEAD` equals `origin/main`.
- No Session is mid-way through a change that would ship half-done: check `git log`, uncommitted files, and ask the Session if unsure. If one is, wait for it and say so.
- Nothing irreversible ships unreviewed: no destructive data migration, no protocol change that clients already in use can't speak, nothing Leo said to hold back.

Then the coordinator:

1. Raises `version`'s minor and `builds.mac` (and `builds.axod` in its own commit if axod changed and nobody bumped it), writes the `CHANGELOG.md` entry for everything shipping since the last publish, then commits and pushes.
2. Runs `bazel build //:report`, checks `bazel-bin/report.txt` shows the new commit, runs `bazel run //:publish`, and confirms `https://axo.leostera.dev/cdn/Axo.app.json`.
3. Deploys whatever else changed by its own procedure (Workers and sites under the Cloudflare Access rules), in the order announced.
4. Tells Leo, and each Session whose work shipped, the version, the builds and the commit. If axod's build changed, it says that updating restarts axod: turns in progress and terminal processes are lost, and Pi Sessions resume, with interrupted ones told they may continue.

If it isn't safe, the coordinator says what blocks it, and releases once it clears. Leo saying to hold a change, or only to try it locally first, overrides this until he says otherwise.

## Runtime safety

- Packaging and publishing are disk and CDN delivery: running Axo and axod keep their mapped code until Leo relaunches or updates. Never close, restart or signal discovered Axo/Axod processes yourself; a restart needs the user's direction.
- Do not run axod as root, and never touch the user's Axod state (`axo_server::default_server_directory()`), Pi transcripts, clipboard or Application Support state while packaging or testing. Tests use isolated fixtures.
- Do not run visual UI tests while the user's Axo is open; the runner refuses, and its safeguard must not be bypassed.
- Isolated component or fixture success does not prove ServiceManagement handoff, Finder launch, physical IME or notification delivery.
