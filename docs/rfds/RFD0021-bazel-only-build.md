# RFD0021 - Axo: One build, `bazel build //...`

- Feature Name: `axo-bazel-only-build`
- Status: Implementing (see As built)
- Author: leostera
- Start Date: 2026-11-01
- Updated: 2026-11-01
- Document Type: Proposal

## Summary

I propose that `bazel build //...` is the only command needed to set up and build everything in the repository. That includes the Rust daemon, every Apple library, app and test bundle, every TypeScript package and the site, the signed `dist/Axo.app`, `apple/Axo.xcodeproj`, `rust-project.json` and, when asked, the phone install. It never fails because the machine lacks something optional. It falls back and says so instead.

Five changes make that happen:

- **One configuration.** `config.json` (committed) holds every value the build uses: version, build numbers, bundle IDs, team, minimum OS versions, simulator, distribution. `config.local.json` (ignored) holds this machine's values: phone UDID, whether to install on the phone, an optional signing identity. No environment variable configures the build.
- **A config extension that looks at the machine.** `@axo_config` merges the two files, checks the machine (signing identities, provisioning profiles, Xcode, simulator runtimes, `pi`, git HEAD) and generates `defs.bzl` with the resolved values and capability flags. BUILD files choose a target or its fallback from those flags.
- **Packaging and signing are Bazel actions.** `scripts/` is deleted. Plist values come from generated fragments, rules_apple signs, `build-mac.sh`'s checks become tests, and actions that write into the workspace (`dist/Axo.app`, `apple/Axo.xcodeproj`) run unsandboxed.
- **TypeScript builds in Bazel** with aspect_rules_js and aspect_rules_ts in one pnpm workspace.
- **Cargo is gone.** External crates are declared with `crate.spec` in `MODULE.bazel`. Every `Cargo.toml`, `Cargo.lock` and `build.rs` is deleted.

Two steps stay explicit because they are deliberate: `bazel run //:publish` uploads the built Mac app to Cloudflare, and `bazel run //apple/AxoPhone:record_snapshots` accepts new phone visual baselines.

## Motivation

Building Axo today means knowing which of several entry points to use and which environment variables to set:

- `scripts/build-mac.sh` packages the Mac app. It picks a signing identity (or `AXO_MAC_SIGNING_IDENTITY`). It reserves a build number in a hidden counter at `~/Library/Application Support/Axo/build-number` (or `AXO_BUILD_NUMBER`, `AXO_BUILD_STATE_DIR`). It builds pi-axo with `npm`, runs a stamped `-c opt` build, unzips it, copies the Pi extension in, patches `Info.plist` with PlistBuddy, signs with `codesign`, checks the result and swaps it into `dist/` with `scripts/replace-app.swift`.
- `scripts/build-phone.sh` keeps a second hidden counter (`AXO_PHONE_BUILD_NUMBER`), builds with `--ios_multi_cpus=arm64` and installs to `AXO_PHONE_DEVICE`, which defaults to a hardcoded UDID.
- `scripts/publish-mac.sh` reads `AXO_CDN_BUCKET` and `AXO_PUBLISH_ALLOW_DIRTY`.
- `scripts/workspace-status.sh` stamps `AXOD_BUILD_NUMBER` or `BUILD_NUMBER` into axod.
- `scripts/phone-visual-loop.sh` and `scripts/phone-swipe-motion.sh` need Python and ffmpeg. The first uses Python only to read the attachments manifest that `xcresulttool` exports. The second films the simulator and tracks a magenta stripe frame by frame to find snaps in a swipe.
- `apple/AxoMac/run_visual_ui_test.sh` reads `AXO_UI_TEST_ONLY` and `AXO_UI_TEST_DESTINATION`, inherits `PATH`, `HOME` and `DEVELOPER_DIR`, runs `npm` inside the test, needs `pi` on `PATH`, regenerates the Xcode project and edits its scheme.
- TypeScript is built by `npm` in each package, with about ten lockfiles (`package-lock.json` per package, plus `bun.lock` at the root and in the site).
- The Rust crates build two ways. `crates/axo-server/build.rs` reads `AXO_BUILD_NUMBER` and `AXO_BUILD_NUMBER_FILE`. `crates/axo-vt/build.rs` reads `AXO_GHOSTTY_VT_DIR` or shells out to `bazel info`.
- `apple/Axo.xcodeproj` exists only after `bazel run //apple:xcodeproj`, and a stale `apple/AxoMac/AxoMac.xcodeproj` is still referenced by `npm run test:mac`.

The same values are written in several places: version `0.1.0` (three Info.plists, two `apple_bundle_version`s), macOS 14.0 (`.bazelrc` twice, four BUILD attributes, two plists), iOS 18.0 (three attributes), team `RGH6S9S55G` (`apple/AxoPhone/BUILD.bazel`, `publish-mac.sh`, `sites/axo.leostera.dev/src/install.ts`), bucket `axo-cdn`, the simulator "iPhone 17 / 27.0".

Build numbers live outside the repository, so two Macs disagree about them, and a build's number depends on how many builds came before it on that Mac.

## Goals

- `bazel build //...` on a Mac with Xcode builds everything, writes `dist/Axo.app` and `apple/Axo.xcodeproj`, and succeeds.
- Every build input is in `config.json`, `config.local.json` or the source tree. No environment variable changes what is built.
- Build numbers are committed values.
- When something optional is missing, the build falls back and reports it in one place.
- One lockfile for TypeScript, none for Cargo.

## Non-goals

- Runtime and test-harness environment variables (`AXO_RELAY_URL`, `AXO_PHONE_PREVIEW_*`, `AXO_PI_*`, `AXO_RESOURCES_DIR`, and the `env = {...}` Bazel sets on tests) stay. They configure a running process, not the build.
- Hermetic Xcode. Xcode is a prerequisite.
- Remote execution or caching.
- Notarization.

## Guide-level explanation

### A fresh checkout

```sh
git clone … axo && cd axo
bazel build //...
```

The first build downloads the Rust, Node and Zig toolchains, builds Ghostty, installs the pnpm workspace and builds everything. At the end:

```
Axo build report (bazel-bin/axo-build-report.txt)
  dist/Axo.app            build 23 (axod 21), signed by RGH6S9S55G
  apple/Axo.xcodeproj     written
  rust-project.json       written
  AxoPhoneDevice          skipped: no provisioning profile "iOS Team Provisioning Profile: dev.leostera.axo.phone"
  phone install           off (set phone.install in config.local.json)
```

On a Mac without Leo's certificate, the same build succeeds with `dist/Axo.app  build 23, ad-hoc signed: launchd will not run its axod`.

### Making a release

1. Bump `builds.mac` in `config.json` (and `builds.axod` when anything axod runs changed), commit.
2. `bazel build //...` writes the new `dist/Axo.app`.
3. `bazel run //:publish` uploads it.

### Deploying to the phone

Put the phone in `config.local.json` once:

```json
{ "phone": { "device": "00008130-00041CE83EFA001C", "install": true } }
```

Bump `builds.phone`, and `bazel build //...` installs and relaunches the app. If the phone is unplugged or locked, the report says so and the build still succeeds.

### Phone visual tests

`bazel test //apple/AxoPhone:AxoPhoneUITests` compares screenshots against `apple/AxoPhone/Snapshots/` and fails on a difference. After reviewing a change, `bazel run //apple/AxoPhone:record_snapshots` copies the latest screenshots over the baselines.

### Editors

Open `apple/Axo.xcodeproj` in Xcode. rust-analyzer reads `rust-project.json`. Both are written by every build.

## Reference-level explanation

### `config.json` and `config.local.json`

`config.json`, committed:

```json
{
  "version": "0.1.0",
  "builds": { "mac": 23, "phone": 41, "axod": 21 },
  "apple": {
    "team": "RGH6S9S55G",
    "macos_min": "14.0",
    "ios_min": "18.0",
    "bundle_ids": {
      "mac": "dev.leostera.axo",
      "mac_ui_tests": "dev.leostera.axo.ui-tests",
      "mac_visual_tests": "dev.leostera.axo.vt",
      "mac_mascot_tests": "dev.leostera.axo.mascot-tests",
      "phone": "dev.leostera.axo.phone",
      "launch_agent": "dev.leostera.axo.axod"
    },
    "phone_profile": "iOS Team Provisioning Profile: dev.leostera.axo.phone",
    "simulator": { "device": "iPhone 17", "os": "27.0" }
  },
  "dist": { "mac_app": "dist/Axo.app" },
  "publish": { "bucket": "axo-cdn", "url": "https://axo.leostera.dev/cdn/Axo.app" }
}
```

`config.local.json`, in `.gitignore`, deep-merged over it. Its keys:

- `phone.device`: a `devicectl` identifier
- `phone.install`: boolean
- `signing.identity`: SHA-1 or name, when several identities for the team exist
- `pi`: path to the Pi CLI, when it is not on `PATH`
- `truststore`: JVM truststore settings, replacing `.bazelrc.local`

A schema (`schemas/config.schema.json`) is checked by the extension. An unknown key or a wrong type is the one configuration error that fails the build. Silently ignoring a typo would be worse.

Values the build cannot read from JSON stay where Bazel requires them: `bazel_dep` versions, the Rust toolchain version and the Ghostty/Zig pins (`ghostty_pin.bzl`).

### `@axo_config`

A module extension in `bazel/config/extension.bzl`:

1. Reads `config.json` and, if present, `config.local.json` with `module_ctx.watch`, so editing either re-runs it.
2. Checks the machine:
   - signing identities for `apple.team` (`security find-identity -v -p codesigning`)
   - the provisioning profile named `apple.phone_profile` in `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and `~/Library/MobileDevice/Provisioning Profiles`
   - `xcodebuild -version`
   - simulator runtimes
   - `pi`
   - git HEAD (watching `.git/HEAD` and the ref it names)
3. Records the workspace root and output base, so build actions can write into the workspace.
4. Generates:
   - `@axo_config//:defs.bzl`: `AXO` (the merged config) and `CAN` (`sign`, `phone_device`, `phone_install`, `pi`, `ui_tests`)
   - `@axo_config//:mac.plist` and `phone.plist`: `CFBundleShortVersionString`, `CFBundleVersion`, `AXODBuildNumber`, `AXOGitCommit`, `LSMinimumSystemVersion`
   - `@axo_config//:axod.env`: `AXO_BUILD_NUMBER`, `CARGO_PKG_VERSION`
   - `@axo_config//:report_facts.json`

Checks that change from minute to minute, such as whether the phone is plugged in, are not made here. The extension only re-runs when a watched file changes. Those checks run in the action that needs them.

A missing git checkout yields `AXOGitCommit = "unknown"`. The "-dirty" suffix is dropped: an extension cannot see edits to working-tree files without watching all of them.

### Versions and build numbers

- `Info.plist` files lose their version keys. `macos_application` and `ios_application` merge `@axo_config//:*.plist` through `infoplists`.
- `apple_bundle_version`, `--embed_label`, `--stamp` and `--workspace_status_command` are removed. Build numbers change cache keys only when they change.
- `crates/axo-server` uses `rustc_env_files = ["@axo_config//:axod.env"]` without `stamp`. `BUILD_NUMBER` and `scripts/workspace-status.sh` are deleted.
- Every minimum-OS value comes from `AXO.apple`. `--macos_minimum_os` and `MACOSX_DEPLOYMENT_TARGET` leave `.bazelrc`. A transition on the app targets applies the minimum to everything they bundle, including axod.

### Fallbacks

The build never fails because of the machine. Each optional piece has a fallback, and each fallback writes one line to the build report:

| Piece | Normal case | Fallback |
|---|---|---|
| Mac signing | identity for `apple.team` | ad-hoc |
| `AxoPhoneDevice` | built with the profile | stub that writes "skipped" |
| Phone install | `devicectl` install and launch | logs "off", "not connected" or "locked" |
| `dist/Axo.app` | swapped in | logs why (e.g. the bundle is held by Finder) |
| `apple/Axo.xcodeproj` | written | logs why |
| Visual UI test bundles | built | built; running them is excluded from `bazel test //...` by tag |

`//:report` is a default target that collects every piece's status file into `bazel-bin/axo-build-report.txt` and prints it.

### Actions that write into the workspace

`dist/Axo.app`, `apple/Axo.xcodeproj`, `rust-project.json` and the phone install are build actions tagged `no-sandbox`, `local`, `no-cache` and `no-remote`. Each writes to `<workspace>/<path>` from `@axo_config` and declares a status file as its only output.

Bazel re-runs an action only when its inputs change, so a deleted `dist/Axo.app` would otherwise stay deleted. `@axo_config` watches each written file's marker (for example `dist/Axo.app/Contents/Info.plist`) and exports a digest of what it found. Deleting the file changes the action's inputs and the next build writes it again.

The `dist/Axo.app` action is `replace-app.swift` as a `swift_binary`. It swaps the bundle in atomically, keeps the previous one for rollback, and never signals a running Axo or axod.

### Mac app

- `//packages/pi-axo` is a `ts_project`. Its output is added to `AxoApp`'s resources under `AxoPi/`.
- axod is wrapped in `macos_command_line_application` so rules_apple signs it, and is embedded in `Contents/Helpers`.
- Signing uses rules_apple with `codesignopts = ["--options=runtime", "--timestamp"]` and the identity from `@axo_config`, or ad-hoc when `CAN.sign` is false. Embedded frameworks (RiveRuntime) are re-signed by rules_apple. The app target is tagged `no-sandbox` for keychain access, and `requires-network` for the timestamp.
- `--define=apple.experimental.tree_artifact_outputs=1` makes the app a directory, not a zip.
- `build-mac.sh`'s checks become `//apple/AxoMac:package_tests`, one test per check:
  - `CFBundleVersion` and `AXODBuildNumber` match config
  - the minimum OS of both executables (via `vtool`) matches `LSMinimumSystemVersion`
  - `axod --version` reports `builds.axod`
  - the LaunchAgent plist lints
  - app and helper are signed by the same team, when signed
- `//apple/AxoMac:Axo.app.zip` is the `ditto` zip the publish step uploads.

### Phone

- `AxoPhoneDevice` is wrapped in a rule with a transition to `ios_multi_cpus = arm64`. The simulator targets keep their own setting, so both build in one invocation. Without the profile it is the stub.
- `//apple/AxoPhone:install` is the workspace-writing action described above. It runs `devicectl` only when `CAN.phone_install`. A failed install or launch is reported, not raised.
- The device UDID moves from `build-phone.sh` to `config.local.json`.

### Phone visual and motion tests

- **Screenshots:** the UI tests save them to `TEST_UNDECLARED_OUTPUTS_DIR` themselves. The XCUITest runner is a Mac process, so it can write there. The comparison from `compare-phone-snapshots.swift` moves into the test target, so a difference fails the test. No `xcresulttool` export and no Python.
- **Motion:** in preview mode the app records the layer's offset on every display frame to a file the test is given (an animatable `GeometryEffect`, see As built). `AxoPhoneMotionTests` checks for speed changes above 2500 pt/s between frames, the threshold the script used. No video, ffmpeg or Python.
- **Recording baselines:** `//apple/AxoPhone:record_snapshots` (`bazel run`) copies the newest screenshots from `bazel-testlogs` into `apple/AxoPhone/Snapshots/`.
- `scripts/phone-visual-loop.sh`, `scripts/phone-swipe-motion.sh` and `scripts/compare-phone-snapshots.swift` are deleted.

### Mac visual UI tests

`run_visual_ui_test.sh` changes:

- It takes a test case through `--test_filter` instead of `AXO_UI_TEST_ONLY`, and gets `pi` from `@axo_config`.
- It stops inheriting the environment and stops running `npm`, because pi-axo is a data dependency.
- It no longer regenerates the project or edits its scheme. The fixture root is passed to the runner through a file in the test's control directory.

It is tagged `requires-mac-ui` and `manual`, so `bazel test //...` skips it and running it by name still works (a `.bazelrc` tag filter would skip it by name too).

### Xcode project

`//apple:xcodeproj` stays a rules_xcodeproj target. Building it does not produce the project: the runner generates it with a Bazel of its own (see As built). `//apple:xcodeproj_install` is a workspace-writing action that runs the runner as `bazel run` would.

The project stays out of git, because every build writes it.

This is the riskiest assumption in this RFD (see Unresolved questions). It has to be proven before anything else.

### TypeScript

- One pnpm workspace at the root (`pnpm-workspace.yaml`, `pnpm-lock.yaml`). Every `package-lock.json` and `bun.lock` is deleted. Duplicate versions are aligned; pi-coding-agent is currently 1.1.0 at the root and 1.3.0 in pi-axo.
- `aspect_rules_js` and `aspect_rules_ts`. Google's `rules_typescript` is archived.
- TypeScript 7 compiles with a native binary (`@typescript/typescript-darwin-arm64`). `ts_project` runs it through its `tsc` override with workers off, or `js_run_binary` calls it directly.
- Each `packages/*` package gets a `ts_project` and its tests as `js_test`. Tests that need a network or a browser are tagged `requires-network` / `requires-browser`.
- The schema check and the mascot freshness check (`packages/axo-mascot`, `check`) are tests.
- `sites/axo.leostera.dev`'s vite and `cf build` run as `js_run_binary`.
- `test:relay` gets axod as a data dependency, not `AXOD_BINARY=../../bazel-bin/…`.
- The root `package.json` scripts are removed.
- `install.ts` and `cloudflare.config.ts` read the team and bucket from `config.json`.

### Rust

- External crates are declared with `crate.spec` and `crate.from_specs` in `MODULE.bazel`, with crate_universe's own lockfile.
- BUILD files list their dependencies (`@crates//:serde`, …) instead of `all_crate_deps()`. Dev-dependencies go on the `rust_test` targets. The edition is `"2024"`.
- All twelve `crates/*/Cargo.toml`, the root `Cargo.toml`, `Cargo.lock`, `crates/axo-server/build.rs`, `crates/axo-vt/build.rs` and `target/` are deleted.
- axod's `cargo_toml_env_vars` is replaced by `@axo_config//:axod.env`.
- `//:rust_project` runs rules_rust's `gen_rust_project` and writes `rust-project.json` through a workspace-writing action.

### Publishing

`//:publish` (`bazel run`) uploads `//apple/AxoMac:Axo.app.zip`:

- It refuses unless the app is signed by `apple.team`.
- It writes `mac/builds/<build>/Axo.app.zip`, then `mac/Axo.app.zip`, to `publish.bucket`.
- It uses the workspace's `cf`.

It never builds anything beyond its dependencies, and it is the only way to publish.

### Removed

- `scripts/`
- `BUILD_NUMBER`
- `.bazelrc.local`
- `apple/AxoMac/AxoMac.xcodeproj`, `apple/.build`
- the five per-package `Package.swift` files (`apple/Package.swift` stays: `MODULE.bazel` reads Swift dependencies from it)
- the stale `.bazelignore` entries (`apple/AxoRPC/.build`, `apple/AxoMac/DerivedData`)
- `HOME`, `SSL_CERT_FILE` and `ZIG_GLOBAL_CACHE_DIR` in the Ghostty repository rules' `environ`

## Rollout

Each step lands on its own and keeps `bazel build //...` green.

1. Spike: build `//apple:xcodeproj` and install the project from a build action. If that fails, revise this RFD before going further.
2. `config.json`, `config.local.json`, the schema and `@axo_config`. Versions, build numbers, IDs and minimum OS versions from config. Delete `BUILD_NUMBER` and the workspace-status command.
3. Cargo to `crate.spec`; delete manifests and `build.rs`; `rust-project.json`.
4. pnpm workspace, rules_js/rules_ts, pi-axo first, then the other packages and the site.
5. Mac signing, package tests, `dist/Axo.app` action, report. Delete `build-mac.sh` and `replace-app.swift`.
6. Phone transition, stub, install action. Delete `build-phone.sh`.
7. Phone visual and motion tests in Swift, `record_snapshots`. Delete the Python/ffmpeg scripts.
8. Mac visual UI test cleanup, `xcodeproj` action, tag filters.
9. `//:publish`. Delete `publish-mac.sh` and `scripts/`.
10. Update `CONTRIBUTING.md`, the `axo-macos-packaging` and `axo-phone-deploy` skills, `sites/axo.leostera.dev/README.md`, `apple/AxoPhone/Snapshots/README.md` and the comments that name the old scripts.

## Testing

- On this Mac: `bazel build //...` from a clean output base succeeds and the report lists every piece as done.
- On a Mac without the certificate or profile (or with them hidden), the build succeeds and the report lists the fallbacks.
- With `config.local.json` absent, and with it present, the build succeeds.
- Deleting `dist/Axo.app` and `apple/Axo.xcodeproj`, then building, restores both.
- Bumping `builds.mac` rebuilds the app bundle without recompiling Swift or Rust.
- `//apple/AxoMac:package_tests` pass on a signed build.
- `bazel test //...` excludes `requires-mac-ui`, `requires-device`, `requires-network` and `requires-browser`.
- No BUILD file, `.bzl` file, `.bazelrc` or build tool reads an environment variable to decide what to build.

## Drawbacks

- Build actions that write into the workspace go against Bazel's model. Bazel won't notice files changed by hand unless they are watched, and two builds running at once could race on `dist/Axo.app`.
- Every build writes `dist/Axo.app`, which takes seconds of copying even when only a test changed. The action re-runs only when the app changes, so in practice it runs when the app changed.
- Committed build numbers mean a release needs a commit. Two branches that both bump will conflict.
- Checks on the machine are cached until a watched file changes. A newly installed profile needs `bazel fetch --force @axo_config` (or a config edit) before it is seen.
- An ad-hoc fallback produces an app that builds but can't run axod under launchd. It must be clearly reported, or it will look like a runtime bug.
- rules_js and rules_ts add a large dependency and a pnpm migration for every package.

## Rationale and alternatives

- **`bazel run` for every side effect.** This is the idiomatic Bazel approach. It was rejected because "check out and run one command" is the goal, and a forgotten `bazel run` leaves a stale app or project.
- **Commit the generated Xcode project and add a staleness test.** The fallback if the spike fails.
- **Build numbers from git (`rev-list --count`).** No bump commits are needed, but numbers depend on history depth and differ between branches, and the axod number has to change only when axod changes. Rejected.
- **Keep `Cargo.toml` as the manifest for crate_universe.** Less churn. Rejected: Cargo would stay half-supported, and two manifests describe the same crate.
- **Keep npm per package and wrap it in genrules.** Faster to land. Rejected: npm would download inside actions, and ten lockfiles would remain.
- **Do nothing.** The scripts work on this Mac, but not anywhere else, and every new value adds another environment variable.

## Prior art

- rules_xcodeproj's own docs install the project with `bazel run`. This RFD relies on building it producing the project.
- aspect_rules_js and rules_ts are the maintained way to build TypeScript in Bazel. TypeScript 7's native compiler is newer than most examples.
- crate_universe supports both `from_cargo` and `from_specs`. This RFD moves from the first to the second.

## Unresolved questions

Before acceptance:

- Does building `//apple:xcodeproj` produce a project that can be copied into `apple/` and work, without its `bazel run` step? The rollout starts with this spike.
- Does rules_apple sign a `macos_command_line_application` embedded through `additional_contents`, or does axod need its own signing action?
- Does `ts_project` work with TypeScript 7's native binary?

During implementation:

- The exact transition that applies `apple.macos_min` to axod.
- Whether `cf build` needs network access, and how the site's build is tagged.

Out of scope:

- Notarization and Developer ID distribution.
- CI.

## As built

What the implementation on `feat/bazel-only-build` settled, where it differs from the proposal above.

- **Xcode project.** Building `//apple:xcodeproj` produces only its runner. The runner writes the generator's package into the output base and builds it with `--config=rules_xcodeproj_generator`, in an output base of its own (`<output_base>/rules_xcodeproj.noindex/build_output_base`). So there is nothing to copy. Instead `//apple:xcodeproj_install` runs the runner from a workspace-writing action. Because the runner's Bazel uses another output base, it never waits on the outer build. The first generation takes about 5 minutes and later ones take seconds. The action reruns when a file under `apple/` comes or goes (`@axo_files//:apple_files.txt`, from a repository that watches the tree) and when the project is deleted. Xcode builds through the result.
- **rust-project.json.** rules_rust's `gen_rust_project` also runs Bazel. `//bazel/rust:rust_project` runs it from an action with `--output-base <output_base>_rust_project`, for the same reason. It reruns when a file under `crates/` comes or goes, or when `MODULE.bazel` or its lock changes. The first run takes about 2 minutes.
- **Signing.** A separate action signs the unpacked bundle after rules_apple builds it (`bazel/apple/sign_mac_app.sh`): the helper, then the frameworks, then the app, with hardened runtime and a secure timestamp, or ad hoc. axod is not a `macos_command_line_application`. `--define=apple.experimental.tree_artifact_outputs` is not used, because the signing action unpacks the zip.
- **Mac app zip.** `//apple/AxoMac:Axo_zip` runs unsandboxed. In the sandbox the bundle's files are symlinks, which `ditto` would zip as symlinks. `//:publish` unzips the archive and compares code directory hashes before uploading.
- **Motion.** The app records the conversation layer's offset with an animatable `GeometryEffect` instead of `CADisplayLink`. SwiftUI hands it the interpolated value of every frame of a spring and every step of a drag, which is the value drawn. `CADisplayLink` would only say that a frame happened.
- **Phone baselines.** The interaction video (`Snapshots/Phone/Videos`) is gone with the scripts that exported it. XCTest still records every UI test run in its result bundle.
- **TypeScript.** `ts_project` works with TypeScript 7's native `tsc` (aspect_rules_ts 3.10.1, `--@aspect_rules_ts//ts:default_to_tsc_transpiler`). Vite builds run unsandboxed: Vite follows the sandbox's symlinks out of its root. `cf build` and `cf dev` shell out to `npx vite`, so the site builds with Vite and Cloudflare's plugin directly. Packages that relied on pnpm hoisting declare what they use. `@types/react` is added to two component libraries' peers through `packageExtensions`.
- **workerd** is pinned only under the site's Cloudflare tooling. Miniflare's tests in `packages/axo-api-worker` need the workerd their miniflare ships with.
- **Remote access explainer.** `docs/explainers/remote-access` typechecks, tests and builds in Bazel. A `write_source_files` test keeps its committed `index.html` equal to the build. `bazel run //docs/explainers/remote-access:update_index_html` rewrites it.
- **Not done yet:**
  - `run_visual_ui_test.sh` still edits the generated scheme with Python, runs `npm` and inherits the environment. It cannot be rewritten and tested while Axo is open.
  - The Feynman specs (`pnpm exec feynman check`) are not a Bazel test.

## Future possibilities

- A CI job that runs `bazel build //...` on a clean Mac and publishes the report.
- `config.json` driving the site's Worker configuration beyond the bucket and team.
