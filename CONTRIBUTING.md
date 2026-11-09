# Contributing to Axo

Thanks for your interest in Axo. The project is under active development, so behavior and internal interfaces can change. For larger changes, open an issue or discussion first to align on scope before investing in an implementation.

## Before you start

- Axo's native app, daemon, and iOS client are developed on macOS with Xcode.
- Bazel (**9.3.0**, pinned in `.bazelversion`) builds the Apple apps, Rust crates and JavaScript packages, from one pnpm workspace (`pnpm-lock.yaml`). Install Xcode and its command-line tools for Apple development. Run `pnpm install` at the root only for editor support or `cf dev`. The Windows preview client uses the .NET SDK; see below.
- `config.json` holds the version, build numbers, bundle ids and minimum OS versions. Settings for your own Mac (your phone, whether to install on it) go in `config.local.json`, which git ignores.
- Never commit API keys, OAuth secrets, signing credentials, personal session data, agent transcripts, or production configuration. Use local development fixtures and environment files, which should remain untracked.

## Build and test

For the Windows preview, follow [`windows/README.md`](windows/README.md) and run
`./windows/build.ps1 -Test`. It builds the Windows Rust targets, the WPF client and the isolated
process/IPC integration tests. `//...` includes Apple targets and remains the macOS entry point.
Windows-specific behavior lives behind platform entry points in the existing Rust crates;
the Mac implementation remains in `crates/axo-server/src/unix.rs` and `crates/axod/src/unix.rs`.

From the repository root:

```sh
bazel build //...
bazel test //...
```

`bazel build //...` builds everything, signs the Mac app with your Apple identity for the team in `config.json` (ad hoc if you have none) and puts it at `dist/Axo.app`. It also writes `apple/Axo.xcodeproj` (one Xcode project for every Apple target, driving Bazel) and `rust-project.json` for rust-analyzer. If this Mac has the phone's provisioning profile it builds the phone app for a device, and installs it when `config.local.json` asks. What it did, and why anything fell back, is in `bazel-bin/report.txt`. It does not fail because a piece of your Mac is missing, only on a broken build or an invalid config.

`bazel test //...` runs every test that needs no desktop, phone or browser of its own. Narrow it to the area you changed, for example `bazel test //crates/...` or `bazel test //packages/pi-axo/...`.

The iPhone UI tests compare screenshots with reviewed baselines (see `apple/AxoPhone/Snapshots/README.md`):

```sh
bazel test //apple/AxoPhone:AxoPhoneUITests --test_filter=AxoPhoneUITests/testVisual
bazel run //apple/AxoPhone:record_snapshots   # after reviewing a change, accept the new screenshots
```

The native Mac visual UI suite is interactive and requires an unlocked desktop, Xcode UI Automation authorization, Axo closed, and macOS 14 or later:

```sh
bazel test //apple/AxoMac:AxoVisualUITestsBazel --test_output=all
```

The visual suite drives a real terminal surface. Do not run it in a locked session or bypass macOS's UI Automation authorization. Its screenshots and test results are written to local temporary/Bazel output directories.

### Adding a dependency

Bazel gives each target only what its `BUILD.bazel` lists, so a dependency goes in two places:

- **npm:** add it to the package's `package.json`, run `pnpm install` at the root (it updates `pnpm-lock.yaml`), then add `:node_modules/<name>` to the targets that import it in that package's `BUILD.bazel`. A package that imports something it does not declare fails to typecheck, even if it worked under npm's hoisting.
- **Rust:** add a `crate.spec` in `MODULE.bazel` and `@crates//:<name>` to the crate's `deps`. There are no `Cargo.toml` files.
- **Swift:** add the remote package to `apple/Package.swift`, run `swift package resolve` in `apple/`, then depend on it from the target's `BUILD.bazel`.

Publishing the Mac app for `curl -fsSL https://axo.leostera.dev/install | sh` is its own step, from a checkout without changes: `bazel run //:publish`.

## Making a change

1. Start with a focused issue or proposal for changes that affect user-visible behavior, architecture, API contracts, or data handling.
2. Keep changes scoped and add or update tests for behavior that can be tested automatically.
3. Update the relevant documentation when setup, user behavior, APIs, or development workflows change. Treat `docs/` architecture notes and proposals as design records; check their status before assuming they describe shipped behavior.
4. Run the relevant checks and report any checks you could not run, including why.
5. Review your diff before submitting. Remove generated artifacts, local configuration, logs, screenshots, and personal data unless a reviewed visual baseline is intentionally part of the change.

## Pull requests and bug reports

A useful pull request includes:

- A short explanation of the problem and the chosen approach.
- The user-visible impact and any limitations or migration considerations.
- The tests and checks run, with results.
- Screenshots or a short recording for visual changes, after checking that they contain no personal or sensitive information.

For bug reports, include the affected platform, steps to reproduce, expected and actual behavior, and relevant sanitized logs. Do not attach Axo session files, Pi transcripts, credentials, or unredacted terminal output.

## Security issues

Please do not report suspected security vulnerabilities in a public issue. Contact the project maintainers privately instead. Include only the information needed to investigate, and avoid sharing real credentials or user data.
